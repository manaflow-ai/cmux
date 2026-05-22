// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CMUXOwlBrowser",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CMUXOwlBrowser", targets: ["CMUXOwlBrowser"])
    ],
    targets: [
        .target(name: "MinimalBrowserCore"),
        .target(name: "OwlMojoSystem"),
        .target(name: "OwlMojoBindingsGenerated"),
        .target(
            name: "OwlMojoBindingsRuntime",
            dependencies: ["OwlMojoBindingsGenerated", "OwlMojoSystem"]
        ),
        .target(
            name: "OwlBrowserCore",
            dependencies: ["OwlMojoBindingsGenerated", "OwlMojoBindingsRuntime", "OwlMojoSystem"]
        ),
        .target(
            name: "OwlChromiumRuntime",
            dependencies: [
                "OwlBrowserCore",
                "OwlMojoBindingsGenerated",
                "OwlMojoBindingsRuntime",
                "OwlMojoSystem"
            ]
        ),
        .target(
            name: "MinimalBrowserUI",
            dependencies: [
                "MinimalBrowserCore",
                "OwlBrowserCore",
                "OwlMojoBindingsGenerated"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "CMUXOwlBrowser",
            dependencies: [
                "MinimalBrowserCore",
                "MinimalBrowserUI",
                "OwlBrowserCore",
                "OwlChromiumRuntime",
                "OwlMojoBindingsGenerated"
            ]
        )
    ]
)
