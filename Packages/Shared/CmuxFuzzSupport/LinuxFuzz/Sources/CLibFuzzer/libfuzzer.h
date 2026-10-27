// libFuzzer's library entry (compiler-rt/lib/fuzzer/FuzzerInterface.h, FuzzerDriver.cpp). Linked by
// -sanitize=fuzzer; a target calls it from its own main, because SwiftPM gives an executable a
// Swift main and libFuzzer's main never runs.
#include <stddef.h>
#include <stdint.h>

int LLVMFuzzerRunDriver(int *argc, char ***argv, int (*callback)(const uint8_t *data, size_t size));
