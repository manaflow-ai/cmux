// swift-tools-version: 6.0
import PackageDescription

// Linux stand-ins for Apple-SDK module surface that first-party code reaches
// for. Packages depend on these products only under `#if os(Linux)` in their
// manifests, so Apple builds never see this package:
//
// * `CmuxLinuxSQLite3` maps the system libsqlite3 to the `SQLite3` module
//   name the Apple SDKs use, so `import SQLite3` compiles unchanged.
// * `CmuxLinuxCompat` declares `public enum Darwin` with the libc calls our
//   code spells `Darwin.close(fd)` (qualified so a type's own `close()` does
//   not capture the call), each forwarding to Glibc, and the
//   `String(localized:defaultValue:)` initializer corelibs Foundation lacks.
//   scripts/ci/linux_swift_portable_imports.py adds its import.
let package = Package(
    name: "CmuxLinuxCompat",
    products: [
        .library(name: "CmuxLinuxSQLite3", targets: ["SQLite3"]),
        .library(name: "CmuxLinuxCompat", targets: ["CmuxLinuxCompat"]),
    ],
    targets: [
        .systemLibrary(
            name: "SQLite3",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(name: "CmuxLinuxCompat"),
    ]
)
