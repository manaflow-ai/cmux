# CmuxMobileCloudUI

The iOS Cloud surface: a section listing the account's Cloud VMs (reached over
the phone's in-process WireGuard tunnel), a machine's terminal catalog, and a
terminal screen that feeds daemon bytes into the embedded libghostty view.

Domain logic (API, identity, wg-quick, session lifecycle, output reduction)
lives in `CmuxMobileCloud` and is tested there without any binary. This package
adds the SwiftUI views plus the `CmuxTerminalClientKit` adapter
(`CmuxTerminalClientCloudAdapter.swift`) that satisfies the domain's transport
seams with the prebuilt Rust client.

## Composition

The app builds one controller and mounts the section:

```swift
let controller = CloudSessionController(
    service: CloudVMService(baseURL: apiBaseURL, tokens: .init(
        accessToken: { try? await coordinator.accessToken() },
        refreshToken: { await coordinator.refreshToken() })),
    identityStore: KeychainCloudDeviceIdentityStore(
        service: appNamespace.keychainService(base: "com.cmuxterm.cloud.wireguard.v1"),
        accessGroup: keychainAccessGroup),
    tunnelStarter: CmuxTerminalClientCloudTunnelStarter(),
    connector: CmuxTerminalClientCloudConnector(),
    stateDirectory: appSupport.appendingPathComponent("cmux-cloud-remote", isDirectory: true),
    deviceName: UIDevice.current.name)

NavigationLink { CloudSectionView(controller: controller) } label: { Text("Cloud") }
```

## Build note

The terminal screen embeds `CmuxMobileTerminal` (GhosttyKit) and the adapter
links `CmuxTerminalClient` (a released xcframework). Neither builds on a bare
checkout without `scripts/setup.sh` (GhosttyKit) and a published
`CmuxTerminalClient` release. The domain package builds and tests on its own.
