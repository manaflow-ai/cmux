import Foundation

/// The identity and task for one in-flight tmux control open.
struct MobileSSHTmuxOpening {
    let id: UUID
    let task: Task<MobileSSHTmuxControlClient, any Error>
}
