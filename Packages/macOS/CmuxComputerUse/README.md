# CmuxComputerUse

Lane A extraction of the dependency audit’s #1 cluster: **ComputerUseRuntime + dependency closure**. Baseline: `02f943788d7177b7998f200e3cbda22eae661c45`. The original cluster contains **11 files / 2,946 physical lines**, with **0 observed outgoing app-target blocking symbols** (0 / 2,946). Other zero-blocker clusters tie on that ratio; the report ranks this one first by lines moved.

This package contains the existing helper runtime and its supporting process identity, cursor artwork, permission, path and session types. It preserves the existing function bodies and app-owned resources.

## Every introduced boundary

1. **Module:** `CmuxComputerUse`, a local library under `Packages/macOS/`, depending on the existing `CmuxControlSocket` and `CmuxSettings` packages. AppKit, Foundation, Darwin, Dispatch, CoreServices and Security remain SDK imports.
2. **Build wiring:** remove the 11 moved file references and their source-build entries; link the library to `cmux` and `cmuxTests` (the targets used by the `cmux` and `cmux-unit` schemes); regenerate workspace package membership.
3. **Consumers:** add `import CmuxComputerUse` to the 45 app source files listed below, and `@testable import CmuxComputerUse` to the 31 existing test files that name moved types. No umbrella re-export, forwarding shim or duplicated source is added.
4. **Visibility:** the exact declarations promoted to `public` are listed below. Helpers not consumed by the app stay internal/private; existing tests reach internals through `@testable`.
5. **Construction:** explicitly spell `ComputerUseSessionScope.init(id:driverSessionID:)`, assigning the same two stored properties as the previously synthesized memberwise initializer. Swift does not synthesize a public memberwise initializer across modules.
6. **Language mode:** compile the new target in Swift 5 mode, matching the executable target. This deliberately excludes a Swift 6 concurrency migration from the pure-move experiment. Existing namespace enums, cached icon state and lifecycle behavior are preserved.
7. **Resource ownership:** `ComputerUseHelperIcon.icns` and the bundled Computer Use helper stay in the executable bundle; `Bundle.main` lookups are unchanged. There is no new resource bundle or path injection.

No new protocols, dependency-injection closures, adapters, managers, singleton accessors, forwarding functions or runtime branches were introduced. Doc comments accompany newly exported declarations.

## Validation

- `swift build --package-path Packages/macOS/CmuxComputerUse`: passed with Xcode Swift 6.2.4.
- `swift test --package-path Packages/macOS/CmuxComputerUse`: two Swift Testing tests passed (session matching/construction and permission-phase transitions).
- SwiftSyntax token comparison: all 11 moved files match the baseline after ignoring comments, `public` modifiers and the one explicitly documented memberwise initializer.
- Xcode project normalization, package grouping, lockfile policy and `git diff --check`: passed.
- Full app and `cmux-unit` build/test validation is still required. The available local environment has no configured Mac build fleet; standalone package success does not prove all host consumers compile.
- No user-visible strings or localization resources changed.

## Reproduce on the Air

Compare the baseline commit above against this branch. Use the same Xcode, configuration, package caches and derived-data policy for both runs. The package intentionally keeps the app’s language mode; performance differences must be measured, not inferred from this extraction.

```sh
swift test --package-path Packages/macOS/CmuxComputerUse
./scripts/reload.sh --tag lane-a-cua
```

Run the `cmux-unit` scheme through the project’s remote/CI validation path as well; the standalone package tests do not compile the whole app test target.

## Construction without the app

```swift
import CmuxComputerUse
let scope = ComputerUseSessionScope(id: "row", driverSessionID: "session")
assert(scope.matches(driverSessionID: "session-mcp-child"))
```

## Moved files

- `Sources/AgentPIDProcessIdentity.swift` → `Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/Process/AgentPIDProcessIdentity.swift` (not this package: the file was a member of both the app and the `cmux-cli` target, and the CLI does not link `CmuxComputerUse`; `CmuxFoundation` is linked by both)
- `Sources/App/AgentCursorPointerView.swift` → `Sources/CmuxComputerUse/AgentCursorPointerView.swift`
- `Sources/App/ComputerUseDaemonProfile.swift` → `Sources/CmuxComputerUse/ComputerUseDaemonProfile.swift`
- `Sources/App/ComputerUseDaemonReadiness.swift` → `Sources/CmuxComputerUse/ComputerUseDaemonReadiness.swift`
- `Sources/App/ComputerUseHelperLaunchConfiguration.swift` → `Sources/CmuxComputerUse/ComputerUseHelperLaunchConfiguration.swift`
- `Sources/App/ComputerUsePermissionRequestOutcome.swift` → `Sources/CmuxComputerUse/ComputerUsePermissionRequestOutcome.swift`
- `Sources/App/ComputerUsePermissionStatus.swift` → `Sources/CmuxComputerUse/ComputerUsePermissionStatus.swift`
- `Sources/App/ComputerUseRuntimePaths.swift` → `Sources/CmuxComputerUse/ComputerUseRuntimePaths.swift`
- `Sources/App/ComputerUseRuntimePermissionPhase.swift` → `Sources/CmuxComputerUse/ComputerUseRuntimePermissionPhase.swift`
- `Sources/App/ComputerUseRuntimeService.swift` → `Sources/CmuxComputerUse/ComputerUseRuntimeService.swift`
- `Sources/App/ComputerUseSessionScope.swift` → `Sources/CmuxComputerUse/ComputerUseSessionScope.swift`

## Public declarations

Each entry is a visibility seam. The single new initializer is also the construction seam described above. Enum cases inherit their enclosing public enum’s visibility.

- `AgentCursorPointerView.swift:83`: `public enum ComputerUseHelperIconRenderer {`
- `AgentCursorPointerView.swift:87`: `public static func image(darkMode: Bool? = nil) -> NSImage? {`
- `AgentCursorPointerView.swift:113`: `public final class AgentCursorPointerView: NSView {`
- `AgentCursorPointerView.swift:115`: `public override var isOpaque: Bool { false }`
- `AgentCursorPointerView.swift:117`: `public override var isFlipped: Bool { true }`
- `AgentCursorPointerView.swift:119`: `public override var acceptsFirstResponder: Bool { false }`
- `AgentCursorPointerView.swift:122`: `public override init(frame frameRect: NSRect) {`
- `AgentCursorPointerView.swift:134`: `public required init?(coder: NSCoder) {`
- `AgentCursorPointerView.swift:139`: `public override func viewDidMoveToWindow() {`
- `AgentCursorPointerView.swift:145`: `public override func viewDidChangeBackingProperties() {`
- `AgentCursorPointerView.swift:151`: `public override func hitTest(_ point: NSPoint) -> NSView? {`
- `AgentCursorPointerView.swift:160`: `public override func draw(_ dirtyRect: NSRect) {`
- `ComputerUsePermissionRequestOutcome.swift:2`: `public enum ComputerUseSystemPermission: String, Hashable, Sendable {`
- `ComputerUseRuntimePaths.swift:5`: `public struct ComputerUseRuntimePaths: Sendable {`
- `ComputerUseRuntimePaths.swift:7`: `public static let daemonSocketEnvironmentKey = "CMUX_CUA_SOCKET_PATH"`
- `ComputerUseRuntimePaths.swift:9`: `public static let codexDaemonSocketEnvironmentKey = "CMUX_CUA_CODEX_SOCKET_PATH"`
- `ComputerUseRuntimePaths.swift:11`: `public static let stateDirectoryEnvironmentKey = "CMUX_CUA_STATE_DIR"`
- `ComputerUseRuntimePaths.swift:13`: `public static let runtimeScopeEnvironmentKey = "CMUX_CUA_RUNTIME_SCOPE"`
- `ComputerUseRuntimePaths.swift:15`: `public static let clientExecutableEnvironmentKey = "CMUX_CUA_CLIENT_PATH"`
- `ComputerUseRuntimePaths.swift:17`: `public static let authenticationTokenEnvironmentKey = "CMUX_CUA_SOCKET_AUTH_TOKEN"`
- `ComputerUseRuntimePaths.swift:19`: `public static let hostAuthenticationTokenEnvironmentKey = "CMUX_CUA_SOCKET_HOST_AUTH_TOKEN"`
- `ComputerUseRuntimePaths.swift:21`: `public static let authenticationTokenFileEnvironmentKey = "CMUX_CUA_AUTH_TOKEN_FILE"`
- `ComputerUseRuntimePaths.swift:24`: `public let scope: String`
- `ComputerUseRuntimePaths.swift:26`: `public let authenticationToken: String`
- `ComputerUseRuntimePaths.swift:32`: `public let hostAuthenticationToken: String`
- `ComputerUseRuntimePaths.swift:34`: `public let computerUseDirectoryURL: URL`
- `ComputerUseRuntimePaths.swift:36`: `public let runtimeDirectoryURL: URL`
- `ComputerUseRuntimePaths.swift:38`: `public let daemonSocketURL: URL`
- `ComputerUseRuntimePaths.swift:40`: `public let codexDaemonSocketURL: URL`
- `ComputerUseRuntimePaths.swift:42`: `public let authenticationTokenFileURL: URL`
- `ComputerUseRuntimePaths.swift:44`: `public let stateDirectoryURL: URL`
- `ComputerUseRuntimePaths.swift:46`: `public let permissionDatabaseDirectoryURL: URL`
- `ComputerUseRuntimePaths.swift:48`: `public let installedHelperDirectoryURL: URL`
- `ComputerUseRuntimePaths.swift:50`: `public let installedHelperAppURL: URL`
- `ComputerUseRuntimePaths.swift:52`: `public let installedHelperExecutableURL: URL`
- `ComputerUseRuntimePaths.swift:55`: `public init(`
- `ComputerUseRuntimeService.swift:10`: `public enum ComputerUseDirectScreenCaptureVerification: Equatable, Sendable {`
- `ComputerUseRuntimeService.swift:22`: `public final class ComputerUseRuntimeService {`
- `ComputerUseRuntimeService.swift:30`: `public let applicationName: String`
- `ComputerUseRuntimeService.swift:32`: `public let stateAuthenticationKey: Data`
- `ComputerUseRuntimeService.swift:60`: `public init(`
- `ComputerUseRuntimeService.swift:95`: `public var helperAppURL: URL? {`
- `ComputerUseRuntimeService.swift:104`: `public var presentationIcon: NSImage? {`
- `ComputerUseRuntimeService.swift:161`: `public var stateDirectoryURL: URL {`
- `ComputerUseRuntimeService.swift:166`: `public func status() -> (accessibility: Bool, screenRecording: Bool) {`
- `ComputerUseRuntimeService.swift:171`: `public var permissionStatusIsKnown: Bool {`
- `ComputerUseRuntimeService.swift:178`: `public func setInitialOnboardingCompletion(_ completed: Bool) {`
- `ComputerUseRuntimeService.swift:184`: `public func onboardingWasPresented() {`
- `ComputerUseRuntimeService.swift:189`: `public func onboardingWasCompleted() {`
- `ComputerUseRuntimeService.swift:197`: `public nonisolated func permissionStatusEvents() -> AsyncStream<Void> {`
- `ComputerUseRuntimeService.swift:206`: `public func setEnabled(_ requested: Bool) async {`
- `ComputerUseRuntimeService.swift:235`: `public func ensureStandaloneHelperInstalled() async -> URL? {`
- `ComputerUseRuntimeService.swift:249`: `public func refreshHelperStatus() async -> (accessibility: Bool, screenRecording: Bool) {`
- `ComputerUseRuntimeService.swift:296`: `public func refreshHelperStatusAfterPermissionChange() async`
- `ComputerUseRuntimeService.swift:325`: `public func openAccessibilitySettings() async -> Bool {`
- `ComputerUseRuntimeService.swift:332`: `public func openScreenRecordingSettings() async -> Bool {`
- `ComputerUseRuntimeService.swift:444`: `public func verifyDirectScreenCaptureOutcome()`
- `ComputerUseRuntimeService.swift:549`: `public func endDriverSession(`
- `ComputerUseRuntimeService.swift:621`: `public func setDriverCursorVisible(`
- `ComputerUseRuntimeService.swift:700`: `public func reassertDriverCursor(`
- `ComputerUseRuntimeService.swift:910`: `public var helperBuildReplacedHandler: (@MainActor () -> Void)?`
- `ComputerUseRuntimeService.swift:1335`: `public func stopForTermination() {`
- `ComputerUseSessionScope.swift:4`: `public struct ComputerUseSessionScope: Sendable {`
- `ComputerUseSessionScope.swift:6`: `public let id: String`
- `ComputerUseSessionScope.swift:8`: `public let driverSessionID: String`
- `ComputerUseSessionScope.swift:14`: `public init(id: String, driverSessionID: String) {`
- `ComputerUseSessionScope.swift:20`: `public static func driverSessionID(surfaceID: UUID) -> String {`
- `ComputerUseSessionScope.swift:25`: `public static func isManagedDriverSessionID(_ candidate: String) -> Bool {`
- `ComputerUseSessionScope.swift:31`: `public static func driverSessionID(containing candidate: String) -> String? {`
- `ComputerUseSessionScope.swift:43`: `public static func isManagedProxySessionID(`
- `ComputerUseSessionScope.swift:56`: `public func matches(driverSessionID candidate: String?) -> Bool {`

## App import sites

- `Sources/AgentHibernationSessionEndResolution.swift`
- `Sources/AgentPortRootIdentity.swift`
- `Sources/App/AgentHibernationController+Confirmation.swift`
- `Sources/App/AgentHibernationController+ProcessExitWaiting.swift`
- `Sources/App/AgentHibernationController+ProcessSignaling.swift`
- `Sources/App/AgentHibernationController+ProcessTermination.swift`
- `Sources/App/AgentHibernationController+SessionEndIntent.swift`
- `Sources/App/AgentHibernationController.swift`
- `Sources/App/AgentHibernationProcessExitEpoch.swift`
- `Sources/App/AgentHibernationProcessSnapshotCoordinator.swift`
- `Sources/App/ComputerUseCuaState.swift`
- `Sources/App/ComputerUseCursorOverlayController.swift`
- `Sources/App/ComputerUseLiveDriverSession.swift`
- `Sources/App/ComputerUseLiveSessionProjection.swift`
- `Sources/App/ComputerUseMenuBarController.swift`
- `Sources/App/ComputerUseMenuBarRow.swift`
- `Sources/App/ComputerUseMenuBarSnapshotStore.swift`
- `Sources/App/ComputerUseOnboardingView.swift`
- `Sources/App/ComputerUseOnboardingWindowController.swift`
- `Sources/App/ComputerUseStateRepository.swift`
- `Sources/App/ComputerUseUXCoordinator.swift`
- `Sources/App/ComputerUseWatchTargetController.swift`
- `Sources/AppDelegate.swift`
- `Sources/DockSplitStore+SessionSnapshot.swift`
- `Sources/HostSettingsActions.swift`
- `Sources/LiveAgentSessionOwner.swift`
- `Sources/LiveAgentSessionOwnerIndex.swift`
- `Sources/LiveAgentSessionOwnerObservation.swift`
- `Sources/PIDPresence.swift`
- `Sources/PortScanner+Process.swift`
- `Sources/PortScanner+Publication.swift`
- `Sources/PortScanner.swift`
- `Sources/RestorableAgentProcessLiveness+ProcessIdentity.swift`
- `Sources/RestorableAgentSession.swift`
- `Sources/RestoredAgentCompletedGeneration.swift`
- `Sources/RestoredAgentLifecycleCoordinator.swift`
- `Sources/RestoredAgentLiveness.swift`
- `Sources/SharedLiveAgentIndexLoader.swift`
- `Sources/TerminalTTYSessionIdentity.swift`
- `Sources/VaultAgentProcessScanner+ForkParentFallback.swift`
- `Sources/Workspace+DetachedSurfaceTransfer.swift`
- `Sources/Workspace+PanelLifecycle.swift`
- `Sources/Workspace.swift`
- `Sources/WorkspaceSidebarAgentRuntimeObservationModel.swift`
- `Sources/cmuxApp.swift`
