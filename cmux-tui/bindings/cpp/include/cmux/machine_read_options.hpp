#pragma once

namespace cmux {
// Explicit catalog metadata never grants session or execution authority.
struct MachineReadOptions { bool catalog = false; };
}  // namespace cmux
