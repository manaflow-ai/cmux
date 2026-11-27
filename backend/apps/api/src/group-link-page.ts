/**
 * GET /g/<group id> (cloud-groups-DESIGN.md slice 1): the https form of a cloud group link. Anonymous
 * and data-free on purpose: the page names only the id it was given and hands off to the app's
 * `cmux://group/<id>` link, so it never shows a group's name to someone who is not its member (the app
 * reads the group with the person's own sign-in). Any other path shape is 404.
 */
export const GROUP_PAGE_PATH = /^\/g\/(grp_[a-z0-9]{20})$/
export const GROUP_PAGE_ANY = /^\/g\/[^/]*$/

export const groupLinkPage = (id: string): Response => {
  const link = `cmux://group/${id}`
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>Open in cmux</title>
<style>body{font:15px -apple-system,system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;background:#111;color:#eee}
main{text-align:center}a.b{display:inline-block;margin-top:12px;padding:10px 18px;border-radius:10px;background:#2a6df4;color:#fff;text-decoration:none}
p{color:#aaa}</style></head>
<body><main><h1>Open in cmux</h1><p>This link opens a cloud group in the cmux app.</p>
<a class="b" href="${link}">Open in cmux</a>
<p>No app? <a href="https://cmux.com" style="color:#8ab4ff">Get cmux</a></p></main>
<script>location.replace(${JSON.stringify(link)})</script></body></html>`
  return new Response(html, { status: 200, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=300", "x-robots-tag": "noindex", "referrer-policy": "no-referrer" } })
}
