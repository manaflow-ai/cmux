// Checks the cmux-page:// path and MIME rules (CEFShim/src/cmux_page_path.h)
// on a real directory tree with symlinks. No CEF needed:
// scripts/cmux-next/test-cmux-page-path-cpp.sh compiles it alone.
#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#include <fstream>
#include <iostream>
#include <string>

#include "../src/cmux_page_path.h"

static int g_cases = 0;
static int g_failures = 0;

static void Expect(bool ok, const std::string& what) {
  ++g_cases;
  if (!ok) {
    ++g_failures;
    std::cerr << "FAIL " << what << "\n";
  }
}

static void Write(const std::string& path) {
  std::ofstream(path) << "x";
}

// A request that must be served from `want_suffix` (relative to the root's
// real path) with `want_mime`.
static void Served(const std::string& root, const std::string& real_root, const std::string& url_path,
                   const std::string& want_suffix, const std::string& want_mime) {
  std::string file;
  std::string mime;
  bool ok = cmux_shim::ResolvePagePath(root, url_path, &file, &mime);
  Expect(ok && file == real_root + "/" + want_suffix && mime == want_mime,
         "served " + url_path + " -> " + (ok ? file + " " + mime : "404"));
}

static void Refused(const std::string& root, const std::string& url_path) {
  std::string file;
  std::string mime;
  bool ok = cmux_shim::ResolvePagePath(root, url_path, &file, &mime);
  Expect(!ok && file.empty() && mime.empty(), "404 for " + url_path + (ok ? " (served " + file + ")" : ""));
}

static void Mime(const std::string& path, const char* want) {
  const char* got = cmux_shim::PageMimeType(path);
  bool ok = want ? (got && std::string(got) == want) : got == nullptr;
  Expect(ok, "mime " + path + " -> " + (got ? got : "refused"));
}

static void Id(const std::string& in, const char* want) {
  std::string out;
  bool ok = cmux_shim::NormalizePageId(in, &out);
  Expect(want ? (ok && out == want) : (!ok && out.empty()), "id '" + in + "' -> " + (ok ? out : "refused"));
}

int main() {
  char tmpl[] = "/tmp/cmux-page-path.XXXXXX";
  if (!mkdtemp(tmpl)) return 2;
  // /tmp is a symlink to /private/tmp: the root is given through it on
  // purpose, so the check must compare real paths on both sides.
  const std::string base = tmpl;
  const std::string root = base + "/root";
  char real_base[PATH_MAX];
  if (!realpath(base.c_str(), real_base)) return 2;
  const std::string real_root = std::string(real_base) + "/root";

  mkdir(root.c_str(), 0700);
  mkdir((root + "/sub").c_str(), 0700);
  mkdir((root + "/sub/deeper").c_str(), 0700);
  mkdir((base + "/outside").c_str(), 0700);
  mkdir((base + "/root2").c_str(), 0700);
  Write(root + "/index.html");
  Write(root + "/app.js");
  Write(root + "/data.txt");
  Write(root + "/sub/page.css");
  Write(root + "/sub/deeper/index.html");
  Write(root + "/a b.json");
  Write(base + "/outside/secret.html");
  Write(base + "/root2/secret.html");
  symlink("../outside/secret.html", (root + "/link-out.html").c_str());  // escapes the root
  symlink("../root2", (root + "/link2").c_str());                        // /root2 prefix trick
  symlink("app.js", (root + "/inner.mjs").c_str());                      // stays inside
  symlink(base.c_str(), (root + "/up").c_str());                         // absolute escape

  Served(root, real_root, "/", "index.html", "text/html");
  Served(root, real_root, "/index.html", "index.html", "text/html");
  Served(root, real_root, "/app.js", "app.js", "text/javascript");
  Served(root, real_root, "/sub/page.css", "sub/page.css", "text/css");
  Served(root, real_root, "/sub/deeper/", "sub/deeper/index.html", "text/html");
  Served(root, real_root, "//sub//page.css", "sub/page.css", "text/css");
  Served(root, real_root, "/a%20b.json", "a b.json", "application/json");
  // A symlink inside the root to a file inside the root: served as the
  // file it resolves to (the real file's extension decides the type).
  Served(root, real_root, "/inner.mjs", "app.js", "text/javascript");

  Refused(root, "");
  Refused(root, "app.js");                   // not absolute
  Refused(root, "/missing.html");
  Refused(root, "/sub");                     // a directory, not a file
  Refused(root, "/sub/");                    // no index.html there
  Refused(root, "/data.txt");                // MIME refusal
  Refused(root, "/../outside/secret.html");
  Refused(root, "/sub/../app.js");           // any .. component, even one that stays inside
  Refused(root, "/./app.js");
  Refused(root, "/%2e%2e/outside/secret.html");
  Refused(root, "/%2E%2E/outside/secret.html");
  Refused(root, "/.%2e/outside/secret.html");
  Refused(root, "/%2e%2e%2foutside%2fsecret.html");  // encoded slashes too
  Refused(root, "/sub%2f..%2f..%2foutside/secret.html");
  Refused(root, "/link-out.html");           // symlink escape
  Refused(root, "/link2/secret.html");       // /root2 is not below /root
  Refused(root, "/up/outside/secret.html");  // absolute symlink escape
  Refused(root, "/app.js%00.html");          // NUL
  Refused(root, "/%zz.html");                // bad escape
  Refused(root, "/app.js%");                 // truncated escape
  Refused(root, "/sub\\..\\app.js");         // backslash
  Refused(base + "/nope", "/index.html");    // missing root
  Refused(root + "/index.html", "/");        // root is a file
  // The root itself is reached through a symlink that leaves nothing out.
  symlink(root.c_str(), (base + "/root-link").c_str());
  Served(base + "/root-link", real_root, "/app.js", "app.js", "text/javascript");

  Mime("/a.html", "text/html");
  Mime("/a.js", "text/javascript");
  Mime("/a.mjs", "text/javascript");
  Mime("/a.css", "text/css");
  Mime("/a.json", "application/json");
  Mime("/a.svg", "image/svg+xml");
  Mime("/a.wasm", "application/wasm");
  Mime("/a.woff", "font/woff");
  Mime("/a.woff2", "font/woff2");
  Mime("/a.ttf", "font/ttf");
  Mime("/a.otf", "font/otf");
  Mime("/a.htm", nullptr);
  Mime("/a.png", nullptr);
  Mime("/a.txt", nullptr);
  Mime("/a.HTML", nullptr);
  Mime("/a", nullptr);
  Mime("/.html", "text/html");
  Mime("/dir.js/file", nullptr);

  Id("cmux.settings", "cmux.settings");
  Id("cmux.history", "cmux.history");
  Id("CMUX.Apps", "cmux.apps");
  Id("cmux.agent", "cmux.agent");
  Id("a-b.c0", "a-b.c0");
  Id("", nullptr);
  Id(".cmux", nullptr);
  Id("cmux.", nullptr);
  Id("cmux..apps", nullptr);
  Id("-cmux", nullptr);
  Id("cmux/apps", nullptr);
  Id("cmux_apps", nullptr);
  Id("cmux apps", nullptr);
  Id("cmux:apps", nullptr);
  Id(std::string(254, 'a'), nullptr);

  std::string cleanup = "rm -rf '" + base + "'";
  if (system(cleanup.c_str()) != 0) std::cerr << "warning: could not remove " << base << "\n";
  std::cout << g_cases << " cases, " << g_failures << " failures\n";
  return g_failures == 0 && g_cases > 0 ? 0 : 1;
}
