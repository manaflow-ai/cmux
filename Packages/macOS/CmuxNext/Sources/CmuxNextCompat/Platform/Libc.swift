// The C library under one import: a module that imports CmuxNextCompat sees Darwin on Apple platforms and
// Glibc (or Musl) on Linux, so its POSIX calls need no `#if canImport` (p15-oracle.md section H). On Darwin
// this file is only the re-export: the system declarations are used as they are, with no wrapper.

#if canImport(Darwin)
@_exported public import Darwin
#elseif canImport(Glibc)
@_exported public import Glibc
internal import Foundation
#elseif canImport(Musl)
@_exported public import Musl
internal import Foundation
#else
#error("CmuxNextCompat needs Darwin, Glibc or Musl")
#endif

#if !canImport(Darwin)
/// Darwin's `pthread_main_np` for the C libraries that do not have it: 1 on the process's main thread,
/// otherwise 0. Foundation keeps the main thread's `pthread_t` from process start (corelibs
/// `_CFIsMainThread`), and Glibc does not export `gettid` to Swift.
public func pthread_main_np() -> Int32 {
    Thread.isMainThread ? 1 : 0
}
#endif
