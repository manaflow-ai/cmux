// swift-tools-version: 5.10
import PackageDescription

// Requires a CEF binary distribution at third_party/cef/current.
// Run scripts/fetch-cef.sh first.
let package = Package(
    name: "CEFKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CEFKit", targets: ["CEFKit"])
    ],
    targets: [
        .target(name: "CCEF"),
        .target(
            name: "CEFKit",
            dependencies: ["CCEF"]
        ),
        // CEF helper subprocess executable. Host apps build it with
        // `swift build --product cefkit-helper` and wrap it into the
        // "<App> Helper*.app" bundles (see Demo/scripts/copy-cef-runtime.sh
        // and cmux scripts/copy-cef-runtime-dev.sh).
        .executableTarget(
            name: "cefkit-helper",
            dependencies: ["CEFKit"]
        ),
    ]
)
