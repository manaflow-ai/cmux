public import CmuxNextCloud
public import Foundation

// The Cloud side of a start the App runs (CloudStartChat): what it may copy, and the steps and
// size its card shows. Pure values; the App keeps the machine, the copy and the chat.
extension AgentPaneCloudStart {
    /// A step of the start as the page's card shows it (``progress(_:to:)``).
    public nonisolated struct Step: Sendable, Equatable {
        public var name: String
        public var folder: String?
        public var machine: String?
        public var size: String?
        public var cloneState: String?
        public var clonePhase: String?
        public var cloneStartedAt: Double?
        public var cloneFinishedAt: Double?
        /// The seed's or copy's live progress (`cmux link seed push`'s stderr lines, ``SeedProgress``).
        public var cloneProgress: SeedProgress?

        public init(name: String, folder: String? = nil, machine: String? = nil, size: String? = nil,
                    cloneState: String? = nil, clonePhase: String? = nil,
                    cloneStartedAt: Double? = nil, cloneFinishedAt: Double? = nil) {
            (self.name, self.folder, self.machine, self.size) = (name, folder, machine, size)
            (self.cloneStartedAt, self.cloneFinishedAt) = (cloneStartedAt, cloneFinishedAt)
            (self.cloneState, self.clonePhase) = (cloneState, clonePhase)
        }
    }

    /// The folder step while its seed or copy runs: the clone row's live progress.
    public nonisolated static func copying(_ progress: SeedProgress, folder: String?, machine: String?, size: String?) -> Step {
        var step = Step(name: "folder", folder: folder, machine: machine, size: size, cloneState: "running", clonePhase: progress.phase)
        step.cloneProgress = progress
        return step
    }

    /// Tells the page's card `step` as it begins.
    @MainActor public func progress(_ step: Step, to view: AgentPaneView) {
        progress(step.name, folder: step.folder, machine: step.machine, size: step.size,
                 cloneState: step.cloneState, clonePhase: step.clonePhase,
                 cloneStartedAt: step.cloneStartedAt, cloneFinishedAt: step.cloneFinishedAt,
                 cloneProgress: step.cloneProgress, to: view)
    }

    /// A machine's size in the card's words: "4 CPU · 16 GB".
    public nonisolated static func sizeText(_ size: CloudMachine.Size?) -> String? {
        guard let cpu = size?.cpu, cpu > 0 else { return nil }
        guard let memory = size?.memoryMb, memory > 0 else { return "\(cpu) CPU" }
        return "\(cpu) CPU · \(Int((Double(memory) / 1024).rounded())) GB"
    }

    /// Whether `folder` is what the send may copy: for a folder the page named, exactly the upload
    /// root the pane checked against its roots; for the tab's own folder (no `cwd`), only that folder
    /// itself, never a Git working copy found above it, which no check covered (a tab in
    /// /repo/project never uploads /repo, its siblings and its history).
    /// The tab's own folder also never when it is the home folder or above it, by its canonical
    /// path too (a tab in /Users would copy every home folder's credentials).
    public nonisolated func uploads(_ folder: CloudMoveFolder, home: String? = NSHomeDirectory()) -> Bool {
        guard cwd != nil else {
            guard folder.subpath.isEmpty else { return false }
            let canonicalHome = home.flatMap(AgentHome.canonical) ?? home
            for path in [folder.root, AgentHome.canonical(folder.root)].compactMap({ $0 })
            where AgentHome.isHomeOrAbove(path, home: canonicalHome) || AgentHome.isHomeOrAbove(path, home: home) {
                return false
            }
            return Self.gitFoldersAreInside(folder.root) // its git folders are copied too
        }
        return uploadRoot == folder.root
    }
}
