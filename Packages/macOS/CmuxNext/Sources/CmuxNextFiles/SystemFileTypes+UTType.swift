#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers

/// The system's type registry: Launch Services through `UTType`.
public struct SystemFileTypes: FileTypeRegistry {
    /// Makes the registry. It holds no state.
    public init() {}

    public func isPackage(pathExtension ext: String) -> Bool {
        // Ask for a folder type: the plain lookup assumes data and can miss
        // bundle types such as `.app` on hosts where LaunchServices is cold.
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory) else { return false }
        return type.conforms(to: .package)
    }

    public func content(pathExtension ext: String) -> FileTypeContent {
        guard let type = UTType(filenameExtension: ext), type.isDeclared else { return .undeclared }
        let text: [UTType] = [.text, .sourceCode, .script, .json, .xml, .propertyList, .yaml]
        return text.contains { type.conforms(to: $0) } ? .text : .other
    }
}
#endif
