// swift-tools-version: 6.2

import Foundation
import PackageDescription

// cmuxview: the benchmark's cmux contender viewer. A full-screen window that presents one cmux.rd/1
// stream with the cmux NEXT app's own code (CmuxNextRemoteView: RemoteRdStreamTransport, the Rust core,
// RemoteDecodePipeline, the Metal presenter), wired the way MacScreenPane/MacScreenSession wire it.
// No logic of its own beyond wiring; see README.md.
//
// The CmuxNext package comes from a cmux checkout at or after the commit that exports the
// CmuxNextRemoteView product (cmux lane/rd-remote-view-product):
//   CMUXVIEW_CMUX=/path/to/cmux swift build -c release
// When this directory sits at cmux's Packages/macOS/CmuxRdView (the compile-check copy), ../CmuxNext is used.
let env = ProcessInfo.processInfo.environment
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let sibling = here.deletingLastPathComponent().appendingPathComponent("CmuxNext")
let cmuxNext: String = {
    if let root = env["CMUXVIEW_CMUX"], !root.isEmpty {
        return URL(fileURLWithPath: root).appendingPathComponent("Packages/macOS/CmuxNext").path
    }
    if FileManager.default.fileExists(atPath: sibling.appendingPathComponent("Package.swift").path) {
        return "../CmuxNext"
    }
    return URL(fileURLWithPath: env["HOME"] ?? "/").appendingPathComponent("ssb/cmux/Packages/macOS/CmuxNext").path
}()

let package = Package(
    name: "CmuxRdView",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "CmuxNext", path: cmuxNext),
    ],
    targets: [
        .executableTarget(
            name: "cmuxview",
            dependencies: [
                .product(name: "CmuxNextRemoteView", package: "CmuxNext"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
