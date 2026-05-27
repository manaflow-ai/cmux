import Foundation

public enum CmuxExtensionSidebarExecutableRequest: Codable, Equatable, Sendable {
    case descriptor
    case render(snapshot: CmuxExtensionSidebarSnapshot, context: CmuxExtensionSidebarRenderContext)
    case handle(mutation: CmuxExtensionSidebarMutation, snapshot: CmuxExtensionSidebarSnapshot)
}

public enum CmuxExtensionSidebarExecutableResponse: Codable, Equatable, Sendable {
    case descriptor(CmuxExtensionSidebarProviderDescriptor)
    case render(CmuxExtensionSidebarRenderModel)
    case command(CmuxExtensionCommandResult)
    case failure(String)
}

public enum CmuxExtensionSidebarExecutable {
    public static func run(provider: any CmuxExtensionSidebarProvider) throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let request = try JSONDecoder.cmuxExtensionSidebarExecutable.decode(
            CmuxExtensionSidebarExecutableRequest.self,
            from: input
        )

        let response: CmuxExtensionSidebarExecutableResponse
        switch request {
        case .descriptor:
            response = .descriptor(provider.descriptor)

        case .render(let snapshot, let context):
            if let contextualProvider = provider as? any CmuxExtensionSidebarContextualProvider {
                response = .render(contextualProvider.render(snapshot: snapshot, context: context))
            } else {
                response = .render(provider.render(snapshot: snapshot))
            }

        case .handle(let mutation, let snapshot):
            guard let mutableProvider = provider as? any CmuxExtensionSidebarMutableProvider else {
                response = .command(CmuxExtensionCommandResult(ok: false))
                break
            }
            response = .command(try mutableProvider.handle(mutation, snapshot: snapshot))
        }

        let output = try JSONEncoder.cmuxExtensionSidebarExecutable.encode(response)
        FileHandle.standardOutput.write(output)
    }
}

public extension JSONDecoder {
    static var cmuxExtensionSidebarExecutable: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public extension JSONEncoder {
    static var cmuxExtensionSidebarExecutable: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
