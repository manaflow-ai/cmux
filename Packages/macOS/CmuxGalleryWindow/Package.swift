// swift-tools-version: 6.2

import PackageDescription

// A light native window for gallery stages: AppKit and WebKit only, no CmuxNext package, so it
// builds in seconds. scripts/cmux-next/gallery-window.py resolves the person's own appearance and
// hands this host one spec; the host only draws windows, the backdrop and the web views.
let package = Package(
    name: "CmuxGalleryWindow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cmux-gallery-window", targets: ["GalleryWindow"]),
    ],
    targets: [
        .executableTarget(name: "GalleryWindow", path: "Sources/GalleryWindow"),
    ]
)
