// Checks cmux_shim::LocalFileSubresourceAllowed against
// schemas/local-file-scope/vectors.json. Input on stdin, one case per line:
// "<0|1> <hex of the document URL> <hex of the request URL>", "-" for an
// empty URL (scripts/cmux-next/test-local-file-scope-cpp.sh converts the JSON).
#include <iostream>
#include <string>

#include "../src/local_file_scope.h"

static std::string FromHex(const std::string& hex) {
  std::string out;
  if (hex == "-") return out;
  for (size_t i = 0; i + 1 < hex.size(); i += 2) out.push_back(static_cast<char>(std::stoi(hex.substr(i, 2), nullptr, 16)));
  return out;
}

int main() {
  int cases = 0, failures = 0;
  std::string expected, document_hex, request_hex;
  while (std::cin >> expected >> document_hex >> request_hex) {
    std::string document = FromHex(document_hex), request = FromHex(request_hex);
    bool want = expected == "1";
    ++cases;
    if (cmux_shim::LocalFileSubresourceAllowed(document, request) != want) {
      ++failures;
      std::cerr << "FAIL want allowed=" << want << " document " << document << " request " << request << "\n";
    }
  }
  std::cout << cases << " cases, " << failures << " failures\n";
  return failures == 0 && cases > 0 ? 0 : 1;
}
