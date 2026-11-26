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
  // GitHub's return after a save on an installation's settings page (#57470): taken by the app in a cmux tab.
  struct SavedCase {
    const char* url;
    bool want;
  };
  const SavedCase saved[] = {
      {"https://console.cmux.dev/integrations/callback?installation_id=42&setup_action=update", true},
      {"https://console-staging.cmux.dev/integrations/callback/?setup_action=update&installation_id=7#x", true},
      {"https://CONSOLE.cmux.dev:443/integrations/callback?installation_id=42&setup_action=update", true},
      // A connect with a state (the console sends it to the app's own link), an error, or another action loads.
      {"https://console.cmux.dev/integrations/callback?state=a.b.c&installation_id=42&setup_action=update", false},
      {"https://console.cmux.dev/integrations/callback?error=x&installation_id=42&setup_action=update", false},
      {"https://console.cmux.dev/integrations/callback?installation_id=42&setup_action=install", false},
      {"https://console.cmux.dev/integrations/callback?installation_id=42", false},
      // The installation must be a number of at most 20 digits.
      {"https://console.cmux.dev/integrations/callback?installation_id=4x&setup_action=update", false},
      {"https://console.cmux.dev/integrations/callback?installation_id=&setup_action=update", false},
      {"https://console.cmux.dev/integrations/callback?installation_id=123456789012345678901&setup_action=update", false},
      // The first value counts, as on the host side.
      {"https://console.cmux.dev/integrations/callback?setup_action=&setup_action=update&installation_id=1", false},
      {"https://console.cmux.dev/integrations/callback?state=&installation_id=1&setup_action=update", true},
      // Another host, path, scheme, or a user in the authority: not the console's callback.
      {"https://evil.com/integrations/callback?installation_id=42&setup_action=update", false},
      {"https://console.cmux.dev.evil.com/integrations/callback?installation_id=42&setup_action=update", false},
      {"https://console.cmux.dev/integrations/other?installation_id=42&setup_action=update", false},
      {"http://console.cmux.dev/integrations/callback?installation_id=42&setup_action=update", false},
      {"https://u@console.cmux.dev/integrations/callback?installation_id=42&setup_action=update", false},
      {"cmux-nightly://integration/complete?installation_id=42&setup_action=update", false},
  };
  for (const SavedCase& c : saved) {
    ++count;
    if (cmux_shim::IsGitHubSavedReturn(c.url) != c.want) {
      ++failures;
      std::cerr << "FAIL saved " << c.url << " want " << c.want << "\n";
    }
  }
  std::cout << count << " cases, " << failures << " failures\n";
  return failures == 0 ? 0 : 1;
}
