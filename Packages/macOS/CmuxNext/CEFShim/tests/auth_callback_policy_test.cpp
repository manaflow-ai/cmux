// Checks cmux_shim::IsAuthCallback: which main-frame navigations of a sign-in
// tab (ASWebAuthenticationSession) end the session with their URL
// (scripts/cmux-next/test-auth-callback-policy-cpp.sh).
#include <iostream>
#include <string>

#include "../src/auth_callback_policy.h"

struct Case {
  const char* url;
  const char* scheme;
  const char* host;
  const char* path;
  bool want;
};

int main() {
  const Case cases[] = {
      // A custom scheme: any URL in it, any case.
      {"myapp://callback?code=1", "myapp", "", "", true},
      {"MyApp:done", "myapp", "", "", true},
      {"com.example.app:/oauth?code=1", "com.example.app", "", "", true},
      {"myapp2://callback", "myapp", "", "", false},
      {"https://myapp/callback", "myapp", "", "", false},
      {"  myapp://x", "myapp", "", "", true},
      // An https callback: that host and path, query and fragment ignored.
      {"https://example.com/cb?code=1", "", "example.com", "/cb", true},
      {"https://EXAMPLE.com./cb/#x", "", "example.com", "/cb", true},
      {"https://user@example.com:443/cb", "", "example.com", "/cb", true},
      {"https://example.com/cb2", "", "example.com", "/cb", false},
      {"https://example.com/", "", "example.com", "/cb", false},
      {"http://example.com/cb", "", "example.com", "/cb", false},
      {"https://evil.com/cb?example.com/cb", "", "example.com", "/cb", false},
      {"https://example.com.evil.com/cb", "", "example.com", "/cb", false},
      {"https://example.com", "", "example.com", "/", true},
      // No callback: nothing ends the session.
      {"https://example.com/cb", "", "", "", false},
      {"myapp://x", "", "", "", false},
      {"", "myapp", "example.com", "/cb", false},
  };
  int failures = 0, count = 0;
  for (const Case& c : cases) {
    ++count;
    if (cmux_shim::IsAuthCallback(c.url, c.scheme, c.host, c.path) != c.want) {
      ++failures;
      std::cerr << "FAIL " << c.url << " scheme=" << c.scheme << " host=" << c.host << " path=" << c.path << " want "
                << c.want << "\n";
    }
  }
  std::cout << count << " cases, " << failures << " failures\n";
  return failures == 0 ? 0 : 1;
}
