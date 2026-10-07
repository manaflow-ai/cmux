import Foundation

/// Why a process serves many tabs at once. Shared processes are reported
/// on their own line and never added to a tab.
public enum SharedRole: String, Sendable, Hashable, CaseIterable, Comparable {
    /// The cmux process itself (window chrome, Ghostty, Chromium's browser process).
    case app
    /// Chromium's GPU process.
    case gpu
    /// Chromium's network service.
    case network
    /// Other Chromium utility processes (storage, audio, ...).
    case utility
    /// Chromium extension renderers (background pages, service workers).
    case extensions

    public static func < (lhs: SharedRole, rhs: SharedRole) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public struct SharedProcess: Sendable, Equatable {
    public var key: ProcessKey
    public var role: SharedRole
    /// For extension renderers: the extension, when known.
    public var label: String?

    public init(key: ProcessKey, role: SharedRole, label: String? = nil) {
        self.key = key
        self.role = role
        self.label = label
    }
}

/// One sample: the tabs under the target, the shared processes, and the
/// counters of every process either names.
public struct ResourceSampleSet: Sendable, Equatable {
    public var tabs: [TabResourceSources]
    public var shared: [SharedProcess]
    public var samples: [ProcessKey: ProcessSample]

    public init(tabs: [TabResourceSources] = [], shared: [SharedProcess] = [], samples: [ProcessKey: ProcessSample] = [:]) {
        self.tabs = tabs
        self.shared = shared
        self.samples = samples
    }

    public static let empty = ResourceSampleSet()
}
