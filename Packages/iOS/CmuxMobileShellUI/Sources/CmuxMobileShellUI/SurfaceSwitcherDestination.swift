import Foundation
import CmuxMobileShellModel

struct SurfaceSwitcherDestination: Identifiable, Equatable {
    enum Kind: Equatable {
        case terminal(MobileTerminalPreview.ID)
        case chat(String)
        case localBrowser(String)
        case browserStream(String)

        var id: String {
            switch self {
            case .terminal(let id):
                return "terminal:\(id.rawValue)"
            case .chat(let id):
                return "chat:\(id)"
            case .localBrowser(let id):
                return "local-browser:\(id)"
            case .browserStream(let id):
                return "browser-stream:\(id)"
            }
        }
    }

    let kind: Kind
    let title: String
    let subtitle: String
    let systemImage: String
    let accessibilityIdentifier: String

    var id: String { kind.id }

    func matchesSearch(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(trimmed)
            || subtitle.localizedCaseInsensitiveContains(trimmed)
    }
}

enum SurfaceSwitcherBrowserRefreshState: Equatable {
    case idle
    case loading
    case failed
}
