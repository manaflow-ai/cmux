// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxSSHNative",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxSSHNative", targets: ["CmuxSSHNative"])],
    dependencies: [.package(path: "../CmuxRemoteConnections")],
    targets: [
        .binaryTarget(name: "CmuxSSHBackend", path: "Artifacts/CmuxSSHBackend.xcframework"),
        .target(name: "CSSHNative", dependencies: ["CmuxSSHBackend"], path: "Sources/CSSHNative", publicHeadersPath: "include",
                cSettings: [.define("LIBSSH_STATIC")]),
        .target(name: "CmuxSSHNative", dependencies: ["CSSHNative", "CmuxRemoteConnections"], path: "Sources/CmuxSSHNative",
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CmuxSSHNativeTests", dependencies: ["CmuxSSHNative", "CSSHNative", "CmuxRemoteConnections"], path: "Tests/CmuxSSHNativeTests")
    ]
)
