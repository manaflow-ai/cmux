// The local file scope of a CEF tab (cx-ary1f). No CEF dependency, so the
// test compiles it alone (scripts/cmux-next/test-local-file-scope-cpp.sh,
// schemas/local-file-scope/vectors.json).
#pragma once

#include <string>

namespace cmux_shim {

// Whether a file: subresource or subframe request from `document_url` loads.
inline bool LocalFileSubresourceAllowed(const std::string& document_url, const std::string& request_url) {
  (void)document_url;
  (void)request_url;
  return true;
}

}  // namespace cmux_shim
