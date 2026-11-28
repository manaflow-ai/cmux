// sites.googleAccounts: the Google accounts signed in to the cmux browser,
// with their /u/{uid}/ index (S.shared.google.listAccounts, Google's
// ListAccounts endpoint). Cookie-only, no tab.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  S.register(
    "googleAccounts",
    (t) => ({
      // [{ uid, name, email, signedOut }]; uid is the /u/{uid}/ and authuser index.
      list: () => S.shared.google.listAccounts(t, "googleAccounts.list"),
    }),
    { summary: "Signed-in Google accounts and their uid (/u/{uid}/) index" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
