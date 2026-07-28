import Foundation
import Observation

@MainActor
@Observable
final class ApplicationSurfacePickerModel {
    var windows: [ApplicationWindowDescriptor] = []
    var query = ""
    var selectedWindowID: UInt32?
    var phase: ApplicationSurfacePickerPhase = .idle

    var filteredWindows: [ApplicationWindowDescriptor] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return windows }
        return windows.filter {
            $0.owner.localizedCaseInsensitiveContains(query)
                || $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    func replaceWindows(_ windows: [ApplicationWindowDescriptor]) {
        self.windows = windows
        if !windows.contains(where: { $0.windowID == selectedWindowID }) {
            selectedWindowID = windows.first?.windowID
        }
    }
}
