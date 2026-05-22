import AppKit
import OwlMojoBindingsGenerated
import UniformTypeIdentifiers

struct NativeFilePickerPanelConfiguration: Equatable {
    let canChooseFiles: Bool
    let canChooseDirectories: Bool
    let allowsMultipleSelection: Bool
    let allowedContentTypes: [UTType]

    init(surface: OwlFreshSurfaceInfo) {
        canChooseDirectories = surface.filePickerUploadFolder
        canChooseFiles = !surface.filePickerUploadFolder
        allowsMultipleSelection = surface.filePickerAllowsMultiple
        allowedContentTypes = canChooseFiles
            ? Self.contentTypes(for: surface.filePickerAcceptTypes)
            : []
    }

    @MainActor
    func apply(to panel: NSOpenPanel) {
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        if canChooseFiles, !allowedContentTypes.isEmpty {
            panel.allowedContentTypes = allowedContentTypes
        }
    }

    static func contentTypes(for acceptTypes: [String]) -> [UTType] {
        var seen = Set<String>()
        var types: [UTType] = []
        for rawAcceptType in acceptTypes {
            let components = rawAcceptType
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for component in components {
                guard let type = contentType(for: component) else {
                    continue
                }
                guard seen.insert(type.identifier).inserted else {
                    continue
                }
                types.append(type)
            }
        }
        return types
    }

    private static func contentType(for acceptType: String) -> UTType? {
        let value = acceptType.lowercased()
        switch value {
        case "image/*":
            return .image
        case "audio/*":
            return .audio
        case "video/*":
            return .movie
        case "text/*":
            return .text
        default:
            break
        }
        if value.hasPrefix(".") {
            return UTType(filenameExtension: String(value.dropFirst()))
        }
        if value.contains("/") {
            return UTType(mimeType: value)
        }
        return UTType(filenameExtension: value)
    }
}
