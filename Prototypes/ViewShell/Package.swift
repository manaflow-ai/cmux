// swift-tools-version: 6.2

import PackageDescription

// The view shell: cmux NEXT's UI in real native windows, without the app. A window is an
// NSWindow with the system titlebar, traffic lights and vibrancy; its content is the webviews
// mock app (webviews/src/gallery/mock-app.html, `chrome=native`) on the in-page mock daemon, loaded
// from the gallery dev server (hot reload) or a built gallery folder. It links nothing of the
// app, so it builds in seconds and only when this file's folder changes. See README.md.
let package = Package(
    name: "ViewShell",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cmux-view-shell", targets: ["ViewShell"]),
    ],
    targets: [
        .executableTarget(
            name: "ViewShell",
            path: "Sources/ViewShell",
            linkerSettings: [
                // Live code (README.md): in Debug the executable's own calls go through bindings that
                // dyld can repoint to a patch (`-interposable`), with classic binds rather than
                // chained fixups so every call site is one.
                .unsafeFlags(["-Xlinker", "-interposable", "-Xlinker", "-no_fixup_chains"], .when(configuration: .debug)),
            ]
        ),
    ]
)
