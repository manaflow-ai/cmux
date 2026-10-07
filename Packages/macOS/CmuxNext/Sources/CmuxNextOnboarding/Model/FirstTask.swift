import Foundation

/// The first tasks onboarding offers. Each runs in a real agent chat in
/// the first-task folder (`FirstTaskFolder`), and what it saves shows up
/// under the chat with Open and Show in Finder.
public nonisolated enum FirstTask: String, CaseIterable, Sendable {
    case note, chart
}
