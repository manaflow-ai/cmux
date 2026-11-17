// Checks the brand list and headers cmux sends to the Chrome Web Store
// (CEFShim/src/webstore_headers.h, no CEF needed;
// scripts/cmux-next/test-shim-webstore-cpp.sh). The store shows "Switch to
// Chrome to install extensions and themes" unless sec-ch-ua names
// "Google Chrome" (with the two x-browser-* headers), measured 2026-11-16.
#include <cstdio>
#include <string>

#include "../src/webstore_headers.h"

using cmux_shim::ChromiumMajorVersion;
using cmux_shim::WebStoreBrandList;
using cmux_shim::WebStoreCopyright;
using cmux_shim::WebStoreSendsChromeHeaders;

static int failures = 0;
static int cases = 0;

static void ExpectBool(bool got, bool want, const char* what) {
  ++cases;
  if (got != want) {
    ++failures;
    std::fprintf(stderr, "FAIL %s: got %d want %d\n", what, got, want);
  }
}

static void Expect(const std::string& got, const std::string& want, const char* what) {
  ++cases;
  if (got != want) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n  got:  %s\n  want: %s\n", what, got.c_str(), want.c_str());
  }
}

int main() {
  const std::string ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36";
  const std::string chromium = "\"Chromium\";v=\"157\", \"Not_A Brand\";v=\"24\"";

  // The banner case: Chromium's own list gets Google Chrome at Chromium's version.
  Expect(WebStoreBrandList(chromium, ua), chromium + ", \"Google Chrome\";v=\"157\"",
         "Chromium's brand list names Google Chrome for the store");
  // A request with no list (a fetch Chromium sent none for): built from the user agent.
  Expect(WebStoreBrandList("", ua), "\"Chromium\";v=\"157\", \"Google Chrome\";v=\"157\"",
         "an empty list is built from the user agent's version");
  // Already there: never twice.
  const std::string chrome = "\"Google Chrome\";v=\"157\", \"Chromium\";v=\"157\"";
  Expect(WebStoreBrandList(chrome, ua), chrome, "a list naming Google Chrome stays as is");
  // No version anywhere: no invented version.
  Expect(WebStoreBrandList("", ""), "", "no version known, no brand");
  Expect(WebStoreBrandList("\"Not_A Brand\";v=\"24\"", ""), "\"Not_A Brand\";v=\"24\"", "no Chromium version, list unchanged");
  // The list's version wins over the user agent's (reduced UA, frozen minor parts).
  Expect(ChromiumMajorVersion("\"Chromium\";v=\"158\"", ua), "158", "the brand list's version wins");
  Expect(ChromiumMajorVersion("", "Chrome/9"), "9", "a short user agent version");
  Expect(ChromiumMajorVersion("\"Chromium\";v=\"\"", ""), "", "an empty version is none");
  // Which requests get them: the store, and the Google bar's promo API from a store page only.
  const std::string store = "https://chromewebstore.google.com/detail/x/laankejkbhbdhmipfmgcngdelahlfoji";
  const std::string promo = "https://ogads-pa.clients6.google.com/$rpc/google.internal.onegoogle.asyncdata.v1.AsyncDataService/GetAsyncData";
  ExpectBool(WebStoreSendsChromeHeaders(store, ""), true, "a store request");
  ExpectBool(WebStoreSendsChromeHeaders("https://ChromeWebStore.Google.com:443/", ""), true, "case and port");
  ExpectBool(WebStoreSendsChromeHeaders(promo, store), true, "the promo API from a store page");
  ExpectBool(WebStoreSendsChromeHeaders(promo, "https://mail.google.com/mail/u/0/"), false, "the promo API from another Google page");
  ExpectBool(WebStoreSendsChromeHeaders(promo, ""), false, "the promo API with no page");
  ExpectBool(WebStoreSendsChromeHeaders("https://ogs.google.com/widget/callout", store), false, "the callout frame itself");
  ExpectBool(WebStoreSendsChromeHeaders("http://chromewebstore.google.com/", ""), false, "not https");
  ExpectBool(WebStoreSendsChromeHeaders("https://chromewebstore.google.com.evil.test/", ""), false, "a lookalike host");
  ExpectBool(WebStoreSendsChromeHeaders("https://evil.test@chromewebstore.google.com/", ""), true, "userinfo is not the host");
  ExpectBool(WebStoreSendsChromeHeaders("https://chromewebstore.google.com@evil.test/", ""), false, "userinfo naming the store");

  // The two headers stay present (the store checks only that both are there).
  Expect(WebStoreCopyright(2026), "Copyright 2026 Manaflow. All rights reserved.", "copyright header");

  std::printf("%d cases, %d failures\n", cases, failures);
  return failures == 0 ? 0 : 1;
}
