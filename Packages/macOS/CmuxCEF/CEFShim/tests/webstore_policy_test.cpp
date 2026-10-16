// Web Store origin and CRX installer routing policy.
#include <cstdio>

#include "../src/webstore_policy.h"

using cmux_shim::IsWebStoreCrxDownloadURL;
using cmux_shim::IsWebStoreCrxURLParts;
using cmux_shim::IsWebStoreURLParts;

static int failures = 0;
static int cases = 0;

static void Check(bool value, const char* name) {
  ++cases;
  if (!value) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", name);
  }
}

int main() {
  Check(IsWebStoreURLParts("https", "chromewebstore.google.com", "/"),
        "modern store origin gets browser headers");
  Check(IsWebStoreURLParts("https", "chrome.google.com", "/webstore/detail/foo"),
        "legacy store redirect gets browser headers");
  Check(!IsWebStoreURLParts("http", "chrome.google.com", "/webstore/detail/foo"),
        "store headers never go over HTTP");
  Check(!IsWebStoreURLParts("https", "chrome.google.com", "/search?q=webstore"),
        "unrelated Google pages do not get store headers");

  Check(IsWebStoreCrxURLParts("https", "clients2.google.com", "/service/update2/crx"),
        "CRX update URL stays with CEF's extension installer");
  Check(!IsWebStoreCrxURLParts("https", "clients2.google.com", "/service/update2/crx/other"),
        "unrelated clients URL uses normal download policy");
  Check(!IsWebStoreCrxURLParts("http", "clients2.google.com", "/service/update2/crx"),
        "CRX installer routing never accepts HTTP");
  Check(IsWebStoreCrxDownloadURL("https://clients2.google.com/service/update2/crx?response=redirect"),
        "CRX URL with query is delegated to CEF");
  Check(!IsWebStoreCrxDownloadURL("https://clients2.google.com/service/update2/crx/other"),
        "CRX path traversal is not delegated");

  std::printf("%d/%d cases passed\n", cases - failures, cases);
  return failures == 0 ? 0 : 1;
}
