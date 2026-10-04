// sites.googleCalendar: events read from the Calendar web app in a background
// tab (each event element carries data-eventid and a full spoken description
// for screen readers), and events created through Calendar's documented
// event template link after a confirmed draft.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URLSearchParams } = root.CmuxBrowserRepl.core;
  const SIGN_IN = [/^https:\/\/accounts\.google\.com\//, /^https:\/\/workspace\.google\.com\//, /\/calendar\/about/];
  const VIEWS = ["day", "week", "month", "agenda"];

  function readEvents(arg) {
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    const out = new Map();
    for (const el of document.querySelectorAll("[data-eventid]")) {
      const id = el.getAttribute("data-eventid");
      if (!id || out.has(id)) continue;
      // The description a screen reader speaks: "10:00am to 11:00am, Title, Person, Location: X, September 30, 2026".
      const hidden = [...el.querySelectorAll("div, span")].map((e) => clean(e.textContent)).filter((s) => s.includes(",")).sort((a, b) => b.length - a.length)[0];
      const description = clean(el.getAttribute("aria-label")) || hidden || clean(el.innerText);
      const parts = description.split(", ");
      const timeLike = /^(all day|\d{1,2}(:\d{2})?\s*(am|pm)?\b.*|\d{1,2}:\d{2}.*)$/i;
      const title = parts.length > 1 && timeLike.test(parts[0]) ? parts[1] : parts[0];
      const location = (parts.find((p) => /^Location: /.test(p)) || "").replace(/^Location: /, "") || undefined;
      out.set(id, { id, title, when: timeLike.test(parts[0]) ? parts[0] : undefined, location, description, url: `${arg.base}r/eventedit/${id}` });
      if (out.size >= arg.limit) break;
    }
    return [...out.values()];
  }

  const pad = (n) => String(n).padStart(2, "0");
  const ymd = (d) => `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}`;
  const stamp = (d) => `${ymd(d)}T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`;
  const toDate = (v, name) => {
    const d = v instanceof Date ? v : new Date(v);
    if (isNaN(d.getTime())) throw new S.SiteError("invalid", `googleCalendar.create: ${name}: expected a date, got ${JSON.stringify(v)}`);
    return d;
  };

  // The event form, checked against the draft right before Save: the title,
  // the start and end as the form shows them (dates and times in the
  // event's time zone: the draft's timeZone, else this Mac's, which the
  // browser and Calendar's default use), and the guests (the organizer, who
  // Calendar lists once there are guests, aside). Fields are read through
  // locators, in the agent's isolated world.
  const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
  function zonedParts(d, timeZone) {
    const f = new Intl.DateTimeFormat("en-US", { timeZone, year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", hourCycle: "h23" });
    const o = {};
    for (const part of f.formatToParts(d)) o[part.type] = part.value;
    return { y: Number(o.year), m: Number(o.month), d: Number(o.day), h: Number(o.hour) % 24, min: Number(o.minute) };
  }
  // "Oct 1, 2026", "Thursday, October 1", "10/1/2026" or "2026-10-01".
  function dateShows(text, p) {
    const s = String(text || "").toLowerCase();
    const nums = (s.match(/\d+/g) || []).map(Number);
    const year = nums.find((n) => n >= 1000);
    if (year !== undefined && year !== p.y) return false;
    const small = nums.filter((n) => n < 1000);
    const named = MONTHS.findIndex((m) => new RegExp(`\\b${m}`).test(s));
    if (named >= 0) return named + 1 === p.m && small.length === 1 && small[0] === p.d;
    return small.length === 2 && small.includes(p.m) && small.includes(p.d) && (p.m === p.d || small[0] !== small[1]);
  }
  // "5:00pm", "5pm", "17:00".
  function timeShows(text, p) {
    const m = /^\s*(\d{1,2})(?::(\d{2}))?\s*(a|p)?\.?\s*m?\.?\s*$/i.exec(String(text || ""));
    if (!m) return false;
    let h = Number(m[1]);
    if (m[3]) {
      if (h < 1 || h > 12) return false;
      h = (h % 12) + (m[3].toLowerCase() === "p" ? 12 : 0);
    }
    return h === p.h && Number(m[2] || 0) === p.min;
  }
  async function fieldText(locator) {
    if (!(await locator.count())) return null;
    const one = locator.first();
    const tag = String(await one._read("tagName", undefined, { timeout: 2000 }, "tag name")).toLowerCase();
    return tag === "input" || tag === "textarea" ? one.inputValue({ timeout: 2000 }) : one.innerText({ timeout: 2000 });
  }
  // Whether Calendar's recurrence menu text ("Does not repeat", "Weekly on
  // Thursday", "Every 2 weeks, 5 times", "Monthly until Dec 31, 2026")
  // repeats as the drafted RRULE: no rule shows "Does not repeat", a rule
  // its frequency and interval, its count and whether it ends on a date.
  function repeatsAs(text, recurrence) {
    if (!recurrence) return /^does not repeat$/i.test(text);
    if (/^does not repeat$/i.test(text)) return false;
    const rule = {};
    for (const part of String(recurrence).replace(/^RRULE:/i, "").split(";")) {
      const [k, v] = part.split("=");
      if (k) rule[k.toUpperCase()] = String(v || "").toUpperCase();
    }
    const unit = { DAILY: "day", WEEKLY: "week", MONTHLY: "month", YEARLY: "year" }[rule.FREQ];
    if (!unit) return false;
    const every = Number(rule.INTERVAL || 1);
    const word = { DAILY: /^(daily|every day|every weekday)\b/i, WEEKLY: /^weekly\b/i, MONTHLY: /^monthly\b/i, YEARLY: /^(annually|yearly)\b/i }[rule.FREQ];
    const freq = every > 1 ? new RegExp(`^every ${every} ${unit}s\\b`, "i").test(text) : word.test(text);
    if (!freq) return false;
    const count = /\b(\d+) times\b/i.exec(text);
    if ((rule.COUNT || null) !== (count ? count[1] : null)) return false;
    return !!rule.UNTIL === /\buntil\b/i.test(text);
  }
  async function checkForm(page, draft) {
    const problems = [];
    const field = (label) => fieldText(page.locator(`[role="main"] [aria-label="${label}"]`));
    const title = await field("Title");
    if (title === null || title.trim() !== draft.title.trim()) problems.push(`title ${JSON.stringify(title)}`);
    const zone = draft.timeZone || new Intl.DateTimeFormat().resolvedOptions().timeZone;
    // All-day dates are calendar days (UTC in the template); the form shows
    // the last day, not the day after.
    const start = draft.allDay ? zonedParts(draft.start, "UTC") : zonedParts(draft.start, zone);
    const end = draft.allDay ? zonedParts(new Date(draft.end.getTime() - 86400000), "UTC") : zonedParts(draft.end, zone);
    const startDate = await field("Start date");
    const endDate = await field("End date");
    if (!dateShows(startDate, start)) problems.push(`start date ${JSON.stringify(startDate)}`);
    // The end date is shown only when it differs from the start.
    if (endDate === null ? start.y !== end.y || start.m !== end.m || start.d !== end.d : !dateShows(endDate, end)) problems.push(`end date ${JSON.stringify(endDate)}`);
    if (!draft.allDay) {
      const startTime = await field("Start time");
      const endTime = await field("End time");
      if (!timeShows(startTime, start)) problems.push(`start time ${JSON.stringify(startTime)}`);
      if (!timeShows(endTime, end)) problems.push(`end time ${JSON.stringify(endTime)}`);
    }
    // The location, description and recurrence the preview showed. A
    // field the form does not show reads as unknown and fails the check.
    const norm = (v) => String(v || "").replace(/[\u200b-\u200d\u2060\ufeff]/g, "").replace(/\s+/g, " ").trim();
    const location = await fieldText(page.locator('[role="main"] [aria-label="Location"], [role="main"] [aria-label="Add location"]'));
    if (location === null || norm(location) !== norm(draft.location)) problems.push(`location ${JSON.stringify(location)}`);
    const description = await fieldText(page.locator('[role="main"] [aria-label="Description"]'));
    if (description === null || norm(description) !== norm(draft.description)) problems.push(`description ${JSON.stringify(description && description.length > 200 ? description.slice(0, 199) + "…" : description)}`);
    const recurrence = await fieldText(page.locator('[role="main"] [aria-label="Recurrence"]'));
    if (recurrence === null || !repeatsAs(norm(recurrence), draft.recurrence)) problems.push(`recurrence ${JSON.stringify(recurrence)}`);
    const listed = page.locator('[role="main"] [data-email]');
    const n = await listed.count();
    const shown = new Set();
    for (let i = 0; i < n && i < 200; i++) shown.add(String((await listed.nth(i).getAttribute("data-email", { timeout: 2000 })) || "").trim().toLowerCase());
    if (n >= 200) problems.push("more than 200 guests");
    shown.delete(String(draft.accountEmail).toLowerCase());
    const want = new Set(draft.guests.map((g) => g.toLowerCase()));
    if (shown.size !== want.size || [...want].some((g) => !shown.has(g))) problems.push(`guests ${[...shown].join(", ") || "none"}`);
    return problems;
  }

  S.register(
    "googleCalendar",
    (t) => {
      const base = (uid) => {
        const u = uid === undefined ? 0 : uid;
        if (!Number.isInteger(u) || u < 0) throw new S.SiteError("invalid", `googleCalendar: uid: expected a non-negative integer, got ${JSON.stringify(uid)}`);
        return `https://calendar.google.com/calendar/u/${u}/`;
      };
      return {
        // [{ id, title, when, location, description, url }] shown in a view.
        // Options: date (default today), view ("week" | "day" | "month" | "agenda"),
        // query (Calendar search instead of a view), limit (100), uid.
        async events(options = {}) {
          const view = options.view || "week";
          if (!VIEWS.includes(view)) throw new S.SiteError("invalid", `googleCalendar.events: view: expected ${VIEWS.join(", ")}, got ${JSON.stringify(view)}`);
          const d = options.date === undefined ? new Date(t.now()) : new Date(options.date);
          if (isNaN(d.getTime())) throw new S.SiteError("invalid", `googleCalendar.events: date: expected a date, got ${JSON.stringify(options.date)}`);
          const b = base(options.uid);
          const url = options.query ? `${b}r/search?q=${encodeURIComponent(options.query)}` : `${b}r/${view}/${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`;
          return t.withTab(url, async (page) => {
            t.assertSignedIn("googleCalendar.events", page, SIGN_IN);
            await t.waitIn(page, () => !!document.querySelector('[role="main"], [data-eventid]'), undefined, { signIn: SIGN_IN, name: "googleCalendar", what: "Google Calendar" });
            await t.sleep(300);
            return page.evaluate(readEvents, { base: b, limit: options.limit || 100 });
          });
        },
        // Draft an event: { title, start, end, allDay, description, location,
        // guests: [emails], timeZone, recurrence: "RRULE:...", uid }.
        // create(draftId, { confirm: true }) saves it (and sends invitations to guests).
        create(input, options) {
          return t.write("googleCalendar", "create", input, options, async (e) => {
            if (!e || typeof e !== "object" || !e.title) throw new S.SiteError("invalid", "googleCalendar.create: expected { title, start, end }");
            const start = toDate(e.start, "start");
            const end = e.end === undefined ? new Date(start.getTime() + (e.allDay ? 86400000 : 3600000)) : toDate(e.end, "end");
            if (end <= start) throw new S.SiteError("invalid", "googleCalendar.create: end must be after start");
            const guests = [].concat(e.guests || []).map(String);
            for (const g of guests) if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(g)) throw new S.SiteError("invalid", `googleCalendar.create: guests: ${JSON.stringify(g)} is not an email address`);
            const q = new URLSearchParams({ action: "TEMPLATE", text: String(e.title), dates: e.allDay ? `${ymd(start)}/${ymd(end)}` : `${stamp(start)}/${stamp(end)}` });
            if (e.description) q.set("details", String(e.description));
            if (e.location) q.set("location", String(e.location));
            if (guests.length) q.set("add", guests.join(","));
            if (e.timeZone) {
              try {
                new Intl.DateTimeFormat("en-US", { timeZone: String(e.timeZone) });
              } catch {
                throw new S.SiteError("invalid", `googleCalendar.create: timeZone: expected an IANA time zone, got ${JSON.stringify(e.timeZone)}`);
              }
              q.set("ctz", String(e.timeZone));
            }
            if (e.recurrence) q.set("recur", String(e.recurrence));
            const uid = e.uid === undefined ? 0 : e.uid;
            base(uid);
            q.set("authuser", String(uid));
            const url = `https://calendar.google.com/calendar/render?${q}`;
            // The draft pins the account by email: u/N is positional.
            const g = S.shared.google;
            const accountEmail = await g.accountEmail(t, "googleCalendar.create", uid);
            return {
              category: guests.length ? "[9] create appointments; [14] sends invitations to guests" : "[9] create appointments",
              summary: `Create "${e.title}" ${e.allDay ? "all day" : ""} ${start.toISOString()} to ${end.toISOString()} as ${accountEmail} (u/${uid})${guests.length ? `, inviting ${guests.join(", ")}` : ""}`.replace(/\s+/g, " "),
              preview: { account: uid, accountEmail, title: String(e.title), start: start.toISOString(), end: end.toISOString(), allDay: !!e.allDay, description: e.description || "", location: e.location || "", guests, timeZone: e.timeZone || null, recurrence: e.recurrence || null },
              run: async () => {
                await g.checkAccount(t, "googleCalendar.create", uid, accountEmail);
                return t.withTab(url, async (page) => {
                  t.assertSignedIn("googleCalendar.create", page, SIGN_IN);
                  const save = page.getByRole("button", { name: "Save", exact: true });
                  await save.first().waitFor({ timeout: 30000 });
                  // The account this event editor saves as, read in the page
                  // right before Save (see gmail.send).
                  await g.checkPageAccount(t, "googleCalendar.create", page, accountEmail);
                  // The form holds the drafted event, nothing else.
                  const problems = await checkForm(page, { title: String(e.title), start, end, allDay: !!e.allDay, timeZone: e.timeZone || null, guests, accountEmail, description: e.description ? String(e.description) : "", location: e.location ? String(e.location) : "", recurrence: e.recurrence ? String(e.recurrence) : null });
                  if (problems.length) throw new S.SiteError("form_mismatch", `googleCalendar.create: the event form does not hold the drafted event (${problems.join("; ")}); nothing was saved. Make a new draft and show it to the user again`);
                  await save.first().click();
                  if (guests.length) {
                    const send = page.getByRole("button", { name: /^Send$/ });
                    await send.first().waitFor({ timeout: 8000 }).then(() => send.first().click(), () => {});
                  }
                  await t.waitIn(page, () => !/\/eventedit/.test(location.pathname) || /Event saved|Saved/.test(document.body.innerText), undefined, { signIn: SIGN_IN, name: "googleCalendar", timeout: 20000, what: "Calendar to save the event" });
                  return { status: "saved", title: String(e.title), start: start.toISOString(), end: end.toISOString() };
                });
              },
            };
          });
        },
      };
    },
    { summary: "Google Calendar events in a view or search; confirmed-draft event creation" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
