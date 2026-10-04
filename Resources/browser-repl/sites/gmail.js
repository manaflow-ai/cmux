// sites.gmail: search, inbox, threads and attachments read from the Gmail
// web app in a background tab of the signed-in browser (the thread list and
// message elements Gmail has kept stable for years: tr.zA rows, .adn
// messages), and mail sent through Gmail's own compose window after a
// confirmed draft. uid is the account index (/mail/u/{uid}/, see
// sites.googleAccounts.list()).
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URL, URLSearchParams } = root.CmuxBrowserRepl.core;
  const SIGN_IN = [/^https:\/\/accounts\.google\.com\//, /^https:\/\/workspace\.google\.com\//, /\/gmail\/about/];

  function readList(arg) {
    const mains = [...document.querySelectorAll('div[role="main"]')];
    const main = mains.find((m) => m.getClientRects().length && getComputedStyle(m).display !== "none") || document;
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    const rows = [...main.querySelectorAll("tr.zA")].slice(0, arg.limit);
    return rows.map((tr) => {
      const idEl = tr.querySelector("[data-thread-id]");
      const legacy = tr.querySelector("[data-legacy-thread-id]");
      const people = [...tr.querySelectorAll(".yX [email], .yW [email]")].map((e) => ({ name: e.getAttribute("name") || clean(e.textContent), email: e.getAttribute("email") }));
      const dateEl = tr.querySelector(".xW [title], td.xW span");
      return {
        threadId: idEl ? idEl.getAttribute("data-thread-id").replace(/^#/, "") : null,
        legacyThreadId: legacy ? legacy.getAttribute("data-legacy-thread-id") : null,
        subject: clean((tr.querySelector(".bog") || {}).textContent),
        snippet: clean((tr.querySelector(".y2") || {}).textContent).replace(/^[-–]\s*/, ""),
        participants: people.filter((p, i) => people.findIndex((q) => q.email === p.email) === i),
        date: dateEl ? dateEl.getAttribute("title") || clean(dateEl.textContent) : null,
        unread: tr.classList.contains("zE"),
      };
    });
  }

  // Gmail's own attachment download URL (https://mail.google.com/mail/...?view=att).
  // Runs in the page (as source) and in the REPL.
  function isAttachmentURL(href) {
    try {
      const u = new URL(href);
      return u.origin === "https://mail.google.com" && /^\/mail\//.test(u.pathname) && u.searchParams.get("view") === "att";
    } catch (e) {
      return false;
    }
  }

  function readThreadBody(arg) {
    const md = (__MD__);
    const isAttachmentURL = (__IS_ATTACHMENT_URL__);
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    const person = (e) => ({ name: e.getAttribute("name") || clean(e.textContent), email: e.getAttribute("email") });
    const messages = [...document.querySelectorAll("div.adn[data-message-id], div[data-message-id].adn")].map((el) => {
      const from = el.querySelector(".gD");
      const date = el.querySelector(".g3");
      const body = el.querySelector(".a3s");
      // Only Gmail's attachment chips (.aQH/.aZo, never inside the message
      // body .a3s, which the sender writes) linking to Gmail's own download URL.
      const attachments = [...el.querySelectorAll('.aQH a[href*="view=att"], .aZo a[href*="view=att"]')].filter((a) => !a.closest(".a3s") && isAttachmentURL(a.href)).map((a) => {
        const box = a.closest(".aQH > *, .aZo") || a;
        const nameEl = box.querySelector(".aV3") || a;
        return { name: clean(nameEl.textContent) || a.getAttribute("download") || "attachment", url: a.href };
      });
      return {
        messageId: (el.getAttribute("data-message-id") || "").replace(/^#/, ""),
        legacyMessageId: el.getAttribute("data-legacy-message-id"),
        from: from ? person(from) : null,
        recipients: [...el.querySelectorAll(".g2")].map(person),
        date: date ? date.getAttribute("title") || clean(date.textContent) : null,
        body: body ? (arg.format === "html" ? body.innerHTML : arg.format === "text" ? body.innerText : md(body)) : null,
        attachments: attachments.filter((x, i) => attachments.findIndex((y) => y.url === x.url) === i),
      };
    });
    return { subject: clean((document.querySelector("h2.hP") || {}).textContent), messages };
  }

  // "thread-f:1784...", "#thread-f:...", a legacy hex id, or a Gmail URL -> hex id for #all/.
  function threadKey(input) {
    const s = String(input || "").trim();
    const f = /thread-f:(\d+)/.exec(s);
    if (f) return BigInt(f[1]).toString(16);
    const hash = /#[^/]+\/([0-9a-f]{16}|[A-Za-z]{2,}[\w-]{20,})$/.exec(s);
    if (hash) return hash[1];
    if (/^[0-9a-f]{16}$/.test(s)) return s;
    throw new S.SiteError("invalid", `gmail: threadId: expected "thread-f:<n>", a 16-digit hex id or a Gmail thread URL, got ${JSON.stringify(input)}`);
  }

  S.register(
    "gmail",
    (t) => {
      const base = (uid) => {
        const u = uid === undefined ? 0 : uid;
        if (!Number.isInteger(u) || u < 0) throw new S.SiteError("invalid", `gmail: uid: expected a non-negative integer, got ${JSON.stringify(uid)}`);
        return `https://mail.google.com/mail/u/${u}/`;
      };
      const mdSource = S.ELEMENT_MARKDOWN;
      const threadFn = new Function("arg", `return (${readThreadBody.toString().replace("(__MD__)", `(${mdSource})`).replace("(__IS_ATTACHMENT_URL__)", `(${isAttachmentURL.toString()})`)})(arg);`);

      async function openThread(page) {
        t.assertSignedIn("gmail", page, SIGN_IN);
        await t.waitIn(page, () => !!document.querySelector("h2.hP, div.adn"), undefined, { signIn: SIGN_IN, name: "gmail", what: "the Gmail thread" });
        const expand = page.locator('[aria-label="Expand all"]');
        if ((await expand.count()) && (await expand.first().isVisible())) await expand.first().click();
        await t.waitIn(page, () => [...document.querySelectorAll("div.adn")].every((m) => m.querySelector(".a3s")), undefined, { signIn: SIGN_IN, name: "gmail", timeout: 8000, what: "every message body" }).catch(() => {});
      }

      async function search(query, options = {}) {
        const limit = options.limit === undefined ? 50 : options.limit;
        const hash = options.page > 1 ? `#search/${encodeURIComponent(query)}/p${options.page}` : `#search/${encodeURIComponent(query)}`;
        return t.withTab(base(options.uid) + hash, async (page) => {
          t.assertSignedIn("gmail.search", page, SIGN_IN);
          await t.waitIn(page, () => !!(document.querySelector("tr.zA") || document.querySelector("td.TC")), undefined, { signIn: SIGN_IN, name: "gmail", what: "Gmail results", timeout: 30000 });
          return page.evaluate(readList, { limit });
        });
      }

      async function thread(threadId, options = {}) {
        const format = options.format || "markdown";
        if (!["markdown", "text", "html"].includes(format)) throw new S.SiteError("invalid", `gmail.thread: format: expected markdown, text or html, got ${JSON.stringify(format)}`);
        const key = threadKey(threadId);
        return t.withTab(`${base(options.uid)}#all/${key}`, async (page) => {
          await openThread(page);
          const r = await page.evaluate(threadFn, { format });
          return { threadId: String(threadId), url: `${base(options.uid)}#all/${key}`, ...r };
        });
      }

      async function sendNow(msg) {
        const bodyStart = msg.body.trim().slice(0, 40);
        if (msg.threadId) {
          const key = threadKey(msg.threadId);
          return t.withTab(`${base(msg.uid)}#all/${key}`, async (page) => {
            await openThread(page);
            // The reply answers the thread as previewed: a message that came
            // in since then could change who a reply (all) goes to.
            const now = (await page.evaluate(threadFn, { format: "text" })).messages.map((m) => m.messageId);
            if (JSON.stringify(now) !== JSON.stringify(msg.messageIds)) throw new S.SiteError("thread_changed", `gmail.send: thread ${msg.threadId} has a new message since the preview (messages ${now.join(", ")}); nothing was sent. Make a new draft and show it to the user again`);
            const button = page.locator(msg.replyAll ? '[data-tooltip="Reply all"], [aria-label="Reply all"]' : '[data-tooltip="Reply"], [aria-label="Reply"]');
            await button.last().click();
            const box = page.locator('div[role="textbox"][aria-label="Message Body"], div[role="textbox"][g_editable="true"]').last();
            await box.waitFor({ timeout: 20000 });
            await box.click();
            await page.keyboard.insertText(msg.body);
            return finishSend(page, box, bodyStart, msg);
          });
        }
        const q = new URLSearchParams({ view: "cm", fs: "1", tf: "1" });
        for (const k of ["to", "cc", "bcc"]) if (msg[k].length) q.set(k, msg[k].join(","));
        if (msg.subject) q.set("su", msg.subject);
        q.set("body", msg.body);
        return t.withTab(`${base(msg.uid)}?${q}`, async (page) => {
          t.assertSignedIn("gmail.send", page, SIGN_IN);
          const box = page.locator('div[role="textbox"][aria-label="Message Body"], div[role="textbox"][g_editable="true"]').first();
          await box.waitFor({ timeout: 30000 });
          return finishSend(page, box, bodyStart, msg);
        });
      }

      async function finishSend(page, box, bodyStart, msg) {
        const shown = (await box.innerText()).replace(/\s+/g, " ");
        if (bodyStart && !shown.includes(bodyStart.replace(/\s+/g, " "))) throw new S.SiteError("compose_mismatch", "gmail.send: the compose window did not receive the drafted body; nothing was sent");
        await page.locator('div[role="button"][data-tooltip^="Send"], div[role="button"][aria-label^="Send"]').last().click();
        await t.waitIn(page, () => /Message sent/.test(document.body.innerText), undefined, { signIn: SIGN_IN, name: "gmail", timeout: 30000, what: "Gmail to confirm the message was sent" });
        // Gmail holds a sent message for its undo window in this page; keep
        // the tab until the Undo action is gone.
        await t.waitIn(page, () => { const a = [...document.querySelectorAll('[role="alert"], .bAq')].map((e) => e.innerText).join(" "); return !/Undo/.test(a); }, undefined, { signIn: SIGN_IN, name: "gmail", timeout: 40000, what: "Gmail's undo window to close" }).catch(() => {});
        return { status: "sent", to: msg.to, subject: msg.subject || null, threadId: msg.threadId || null };
      }

      const list = (v, name) => {
        if (v === undefined || v === null || v === "") return [];
        const arr = Array.isArray(v) ? v : String(v).split(",");
        return arr.map((x) => String(x).trim()).filter(Boolean).map((x) => {
          if (!/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(x)) throw new S.SiteError("invalid", `gmail.send: ${name}: ${JSON.stringify(x)} is not an email address`);
          return x;
        });
      };

      return {
        // { threadId, legacyThreadId, subject, snippet, participants, date, unread }[]; Gmail search operators work.
        search: (query, options) => {
          if (typeof query !== "string" || !query.trim()) throw new S.SiteError("invalid", `gmail.search: query: expected Gmail search text, got ${JSON.stringify(query)}`);
          return search(query, options);
        },
        inbox: (options = {}) => search("in:inbox", options),
        // { threadId, url, subject, messages: [{ messageId, from, recipients, date, body, attachments }] }
        thread,
        // Downloads one attachment (by name or index across the thread); { path, name, contentType }.
        async attachment(threadId, which, options = {}) {
          const th = await thread(threadId, options);
          const all = th.messages.flatMap((m) => m.attachments);
          const pick = typeof which === "number" ? all[which] : all.find((a) => a.name === which);
          if (!pick) throw new S.SiteError("not_found", `gmail.attachment: no attachment ${JSON.stringify(which)}; attachments: ${all.map((a) => a.name).join(", ") || "none"}`);
          if (!isAttachmentURL(pick.url)) throw new S.SiteError("invalid", `gmail.attachment: ${pick.url} is not a Gmail attachment URL`);
          let r = await t.fetch(pick.url);
          if ((r.headers.get("content-type") || "").startsWith("text/html") && /disp=safe/.test(pick.url)) r = await t.fetch(pick.url.replace("disp=safe", "disp=attd"));
          if (!r.ok) throw new S.SiteError("http", `gmail.attachment: HTTP ${r.status}`);
          const ext = (/\.[a-z0-9]{1,8}$/i.exec(pick.name) || [""])[0];
          const file = t.outputPath(options, ext, pick.name.replace(/\.[a-z0-9]{1,8}$/i, ""));
          t.fs.writeFileSync(file, t.Buffer.from(await r.arrayBuffer()));
          return { path: file, name: pick.name, contentType: r.headers.get("content-type") };
        },
        // Draft: { to, cc, bcc, subject, body, uid } or a reply { threadId, body, replyAll, uid }.
        // Returns a draft; send(draftId, { confirm: true }) sends it through Gmail.
        send(input, options) {
          return t.write("gmail", "send", input, options, async (m) => {
            if (!m || typeof m !== "object") throw new S.SiteError("invalid", "gmail.send: expected { to, subject, body } or { threadId, body }");
            const msg = { uid: m.uid === undefined ? 0 : m.uid, to: list(m.to, "to"), cc: list(m.cc, "cc"), bcc: list(m.bcc, "bcc"), subject: m.subject ? String(m.subject) : "", body: String(m.body || ""), threadId: m.threadId || null, replyAll: !!m.replyAll };
            base(msg.uid);
            if (msg.threadId) threadKey(msg.threadId);
            else if (!msg.to.length && !msg.cc.length && !msg.bcc.length) throw new S.SiteError("invalid", "gmail.send: a new message needs at least one recipient");
            if (!msg.body.trim() && !m.allowEmptyBody) throw new S.SiteError("invalid", "gmail.send: the body is empty; pass allowEmptyBody: true if that is intended");
            // The draft pins the sending account by email (u/N is positional)
            // and a reply the thread's messages as previewed.
            const g = S.shared.google;
            const accountEmail = await g.accountEmail(t, "gmail.send", msg.uid);
            if (msg.threadId) msg.messageIds = (await thread(msg.threadId, { uid: msg.uid, format: "text" })).messages.map((x) => x.messageId);
            return {
              category: "[9] representational communication; [14] transmits data to the recipients",
              summary: msg.threadId ? `Reply${msg.replyAll ? " all" : ""} in Gmail thread ${msg.threadId} as ${accountEmail} (u/${msg.uid})` : `Email to ${[...msg.to, ...msg.cc, ...msg.bcc].join(", ")} from ${accountEmail} (u/${msg.uid}): "${msg.subject}"`,
              preview: msg.threadId ? { account: msg.uid, accountEmail, threadId: msg.threadId, messageIds: msg.messageIds, replyAll: msg.replyAll, body: msg.body } : { account: msg.uid, accountEmail, to: msg.to, cc: msg.cc, bcc: msg.bcc, subject: msg.subject, body: msg.body },
              run: async () => {
                await g.checkAccount(t, "gmail.send", msg.uid, accountEmail);
                return sendNow(msg);
              },
            };
          });
        },
      };
    },
    { summary: "Gmail search, inbox, threads, attachments; confirmed-draft send and reply" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
