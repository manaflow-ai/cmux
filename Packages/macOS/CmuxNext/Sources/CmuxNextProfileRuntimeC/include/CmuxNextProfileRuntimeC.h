#ifndef CMUX_NEXT_PROFILE_RUNTIME_C_H_
#define CMUX_NEXT_PROFILE_RUNTIME_C_H_
#ifdef __cplusplus
extern "C" {
#endif
// The compiler-rt profile runtime's entry points (compiler-rt/lib/profile/
// InstrProfiling.h), which a -profile-generate / -fprofile-instr-generate
// link brings in. Declared here as Chromium declares them
// (base/test/clang_profiling.cc), so Swift calls them with the C calling
// convention. Only the profile build (CMUX_PGO_PROFILE) calls them, so no
// other build references the symbols (ProfileFlush).

// Writes the counters to the current file; 0 on success.
int __llvm_profile_write_file(void);
// Sets every counter to zero.
void __llvm_profile_reset_counters(void);
// Names the file (a LLVM_PROFILE_FILE pattern) for the next write and the
// write at exit; the runtime copies the name.
void __llvm_profile_set_filename(const char *name);

#ifdef __cplusplus
}
#endif
#endif  // CMUX_NEXT_PROFILE_RUNTIME_C_H_
