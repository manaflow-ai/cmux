// swift-tools-version: 6.0

import PackageDescription
<<<<<<< HEAD
import Foundation

=======
>>>>>>> origin/main

// Platform-neutral Home client core: the conversation model (same shapes as the
// conversation owner's wire contract), the HomeSource protocol every backend
// implements (mock, local daemon, cloud), the confirmed mirror + intent log,
// contact parsing for invites, and search over Home messages. No UIKit/AppKit,
// so it builds and tests on macOS with `swift test` and serves iOS and macOS.
let package = Package(
    name: "CmuxHomeCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxHomeCore", targets: ["CmuxHomeCore"]),
    ],
    dependencies: [
<<<<<<< HEAD
        .package(path: "../CmuxEgress"),
        // Agent questions (plans/cmux-next/agent-questions.md): the `question` part's model.
        .package(path: "../CmuxAgentQuestion"),
        // The cloud build space a dev build's requests carry (`CMUXBuildSpace`, `X-Cmux-Build-Space`).
        .package(path: "../CMUXAuthCore"),
=======
        // Agent questions (plans/cmux-next/agent-questions.md): the `question` part's model.
        .package(path: "../CmuxAgentQuestion"),
>>>>>>> origin/main
    ],
    targets: [
        .target(
            name: "CmuxHomeCore",
<<<<<<< HEAD
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
                .product(name: "CmuxEgress", package: "CmuxEgress"),
            ],
=======
            dependencies: [.product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion")],
>>>>>>> origin/main
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // One condition-polling wait for every suite (no per-suite yield loops).
        .target(
            name: "CmuxHomeCoreTestSupport",
            path: "Tests/CmuxHomeCoreTestSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxHomeCoreTests",
<<<<<<< HEAD
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CmuxHomeCore",
                "CmuxHomeCoreTestSupport",
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            ],
            // MessagePreviewTests reads it by path, as the Rust port's tests do: not a bundle resource.
            exclude: ["MessagePreviewCases.json"],
=======
            dependencies: ["CmuxHomeCore", "CmuxHomeCoreTestSupport"],
>>>>>>> origin/main
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
<<<<<<< HEAD

#if os(Linux)
// CryptoKit is Apple-only: a build for Linux takes the same API from swift-crypto (`import Crypto`). Only
// the Linux package jobs (swift-linux-packages.yml) set CMUX_SWIFTPM_TARGET_LINUX; a build for an Apple
// platform on a Linux host (the fleet) keeps CryptoKit and resolves no remote package, so this package
// has no Package.resolved (scripts/check-package-resolved-policy.py skips this block).
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"))
    for target in package.targets where target.name == "CmuxHomeCore" || target.name == "CmuxHomeCoreTests" {
        target.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
    }
}
#endif
=======
>>>>>>> origin/main
