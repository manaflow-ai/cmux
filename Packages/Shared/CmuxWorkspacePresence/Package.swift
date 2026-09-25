// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxWorkspacePresence",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "CmuxWorkspacePresence", targets: ["CmuxWorkspacePresence"])],
    dependencies: [.package(path: "../CMUXMobileCore")],
    targets: [
        .target(name: "CmuxWorkspacePresence", dependencies: ["CMUXMobileCore"]),
        .testTarget(name: "CmuxWorkspacePresenceTests", dependencies: ["CmuxWorkspacePresence", "CMUXMobileCore"])
    ],
    swiftLanguageModes: [.v6]
)
