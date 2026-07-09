#if DEBUG
public import Foundation

/// The fixed parameters of the DEBUG "open stress workspaces with loaded
/// surfaces" harness.
///
/// The harness creates a batch of identical workspaces (each a four-pane split
/// with several terminal tabs per pane), forces every terminal surface to load,
/// and logs creation/load timing so a developer can measure sidebar and
/// terminal-mount performance at scale. These knobs were `private let`
/// constants on `AppDelegate`; they are pure values with no dependency on any
/// live app object, so they live here as a tested value type that
/// ``DebugStressWorkspaceDriver`` reads.
///
/// Isolation: a pure `Sendable` value. It carries no references and performs no
/// I/O.
public struct DebugStressWorkspaceConfiguration: Sendable, Equatable {
    /// Title prefix applied to each created workspace (`"Debug Perf - <n>"`).
    public var workspaceTitlePrefix: String

    /// Number of workspaces to create.
    public var workspaceCount: Int

    /// Number of terminal panes per workspace (a four-pane split layout).
    public var paneCount: Int

    /// Number of terminal tabs per pane (including the pane's initial tab).
    public var tabsPerPane: Int

    /// How many loop iterations run before yielding to the main run loop, so the
    /// UI stays responsive while the batch is built.
    public var yieldInterval: Int

    /// How long to wait for every queued terminal surface to finish loading
    /// before giving up.
    public var surfaceLoadTimeoutSeconds: TimeInterval

    /// Creates a configuration. The harness uses
    /// ``DebugStressWorkspaceConfiguration/standard`` in production; tests
    /// construct smaller batches.
    public init(
        workspaceTitlePrefix: String,
        workspaceCount: Int,
        paneCount: Int,
        tabsPerPane: Int,
        yieldInterval: Int,
        surfaceLoadTimeoutSeconds: TimeInterval
    ) {
        self.workspaceTitlePrefix = workspaceTitlePrefix
        self.workspaceCount = workspaceCount
        self.paneCount = paneCount
        self.tabsPerPane = tabsPerPane
        self.yieldInterval = yieldInterval
        self.surfaceLoadTimeoutSeconds = surfaceLoadTimeoutSeconds
    }

    /// The production knobs matching the legacy `AppDelegate` constants:
    /// 20 workspaces, 4 panes each, 4 tabs per pane, yielding every 4
    /// iterations, with a 10-second per-surface load timeout.
    public static let standard = DebugStressWorkspaceConfiguration(
        workspaceTitlePrefix: "Debug Perf - ",
        workspaceCount: 20,
        paneCount: 4,
        tabsPerPane: 4,
        yieldInterval: 4,
        surfaceLoadTimeoutSeconds: 10.0
    )

    /// The total number of terminal surfaces the batch should produce
    /// (`workspaceCount * paneCount * tabsPerPane`), used for the summary log.
    public var expectedSurfaceCount: Int {
        workspaceCount * paneCount * tabsPerPane
    }
}
#endif
