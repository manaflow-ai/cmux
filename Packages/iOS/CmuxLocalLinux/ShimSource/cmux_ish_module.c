#include "cmux_ish.h"

// The implementation is linked from IshKernelBinary. This anchor gives
// SwiftPM a regular C target that owns the public header and Clang module,
// without compiling cmux_ish.c a second time.
int cmux_ish_module_anchor(void) {
    return 0;
}
