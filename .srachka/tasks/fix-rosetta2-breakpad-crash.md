# Fix Rosetta 2 assertion crash caused by Breakpad thread_get_state

## Context

Issue: https://github.com/manaflow-ai/cmux/issues/1077

On Apple Silicon Macs, cmux crashes with:
```
assertion failed [lr_abi_info.kind == AbiKind::TranslatedCode]: expected saved LR to be in translated code
(ThreadContextRegisterState.cpp:443 guest_gpr_state_from_host_state)
```

## Root cause

GhosttyKit.xcframework is built as a universal binary (arm64 + x86_64). This causes macOS to attach Rosetta 2 to the process. When sentry-native's Breakpad backend calls `thread_get_state()` on threads running native arm64 code (Metal, CoreText, etc.), Rosetta 2 tries to translate ARM64 registers to x86_64 and hits an assertion failure.

## Proposed fix

Switch sentry-native from Breakpad backend to `inproc` backend on arm64 builds. The `inproc` backend does not call `thread_get_state()` on other threads, avoiding the Rosetta 2 conflict.

Alternative approaches (if inproc switch is not feasible):
1. Build GhosttyKit as arm64-only (remove x86_64 slice)
2. Remove sentry-native Breakpad entirely, keep only Sentry Cocoa SDK

## Acceptance criteria

- No more Rosetta 2 assertion crash on Apple Silicon
- Crash reporting still works (sentry)
- No regression on x86_64 Intel Macs
