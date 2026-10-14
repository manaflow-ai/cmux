// swift-tools-version: 6.2

import PackageDescription

// CmuxWorkspacesKit: three candidate designs for the cmux-next iOS
// workspaces home (no sidebar, no hamburger). See README.md.
// The UI is iOS 26+; the model and logic also build on macOS so
// `swift test` runs on a Mac.
let package = Package(
    name: "CmuxWorkspacesKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "CmuxWorkspacesKit", targets: ["CmuxWorkspacesKit"]),
    ],
    targets: [
        .target(name: "CmuxWorkspacesKit"),
        .testTarget(name: "CmuxWorkspacesKitTests", dependencies: ["CmuxWorkspacesKit"]),
    ],
    swiftLanguageModes: [.v6]
)
