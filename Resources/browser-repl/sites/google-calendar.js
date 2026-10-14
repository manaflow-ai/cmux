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
          return t.write("googleCalendar", "create", input, options, (e) => {
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
            if (e.timeZone) q.set("ctz", String(e.timeZone));
            if (e.recurrence) q.set("recur", String(e.recurrence));
            const uid = e.uid === undefined ? 0 : e.uid;
            base(uid);
            q.set("authuser", String(uid));
            const url = `https://calendar.google.com/calendar/render?${q}`;
            return {
              category: guests.length ? "[9] create appointments; [14] sends invitations to guests" : "[9] create appointments",
              summary: `Create "${e.title}" ${e.allDay ? "all day" : ""} ${start.toISOString()} to ${end.toISOString()} in account u/${uid}${guests.length ? `, inviting ${guests.join(", ")}` : ""}`.replace(/\s+/g, " "),
              preview: { account: uid, title: String(e.title), start: start.toISOString(), end: end.toISOString(), allDay: !!e.allDay, description: e.description || "", location: e.location || "", guests, timeZone: e.timeZone || null, recurrence: e.recurrence || null },
              run: () =>
                t.withTab(url, async (page) => {
                  t.assertSignedIn("googleCalendar.create", page, SIGN_IN);
                  const save = page.getByRole("button", { name: "Save", exact: true });
                  await save.first().waitFor({ timeout: 30000 });
                  await save.first().click();
                  if (guests.length) {
                    const send = page.getByRole("button", { name: /^Send$/ });
                    await send.first().waitFor({ timeout: 8000 }).then(() => send.first().click(), () => {});
                  }
                  await t.waitIn(page, () => !/\/eventedit/.test(location.pathname) || /Event saved|Saved/.test(document.body.innerText), undefined, { signIn: SIGN_IN, name: "googleCalendar", timeout: 20000, what: "Calendar to save the event" });
                  return { status: "saved", title: String(e.title), start: start.toISOString(), end: end.toISOString() };
                }),
            };
          });
        },
      };
    },
    { summary: "Google Calendar events in a view or search; confirmed-draft event creation" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
