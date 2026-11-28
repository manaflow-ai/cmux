// Checks cmux_shim::CEFHandsOffLocalFile against schemas/local-file-handoff/vectors.json.
// Input on stdin, one case per line: "<0|1> <hex of the URL bytes>"
// (scripts/cmux-next/test-local-file-handoff-cpp.sh converts the JSON).
#include <iostream>
#include <string>

#include "../src/local_file_handoff.h"

static std::string FromHex(const std::string& hex) {
  std::string out;
  for (size_t i = 0; i + 1 < hex.size(); i += 2) out.push_back(static_cast<char>(std::stoi(hex.substr(i, 2), nullptr, 16)));
  return out;
}

int main() {
  int cases = 0, failures = 0;
  std::string expected, hex;
  while (std::cin >> expected) {
    if (!(std::cin >> hex)) hex.clear();
    if (hex == "-") hex.clear();
    std::string url = FromHex(hex);
    bool want = expected == "1";
    ++cases;
    if (cmux_shim::CEFHandsOffLocalFile(url) != want) {
      ++failures;
      std::cerr << "FAIL handoff=" << !want << " want " << want << " for " << url << "\n";
    }
  }
  std::cout << cases << " cases, " << failures << " failures\n";
  return failures == 0 && cases > 0 ? 0 : 1;
}
