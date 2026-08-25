import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct MobileExternalNavigationTargetResolverTests {
    private let scheme = "cmux-ios-test"
    private let workspaceUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let paneUUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let terminalUUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let stableWorkspaceUUID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private let stableSurfaceUUID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    @Test func resolvesWorkspaceAndTerminalSurfaceTargets() throws {
        let workspace = makeWorkspace()
        let resolver = MobileExternalNavigationTargetResolver(workspaces: [workspace])
        let workspaceRequest = try request("\(scheme)://workspace/\(workspaceUUID.uuidString)")
        let surfaceRequest = try request(
            "\(scheme)://workspace/\(workspaceUUID.uuidString)/surface/\(terminalUUID.uuidString)"
        )

        #expect(
            resolver.resolve(workspaceRequest)
                == .resolved(.init(workspaceID: workspace.id, selection: nil))
        )
        #expect(
            resolver.resolve(surfaceRequest)
                == .resolved(
                    .init(
                        workspaceID: workspace.id,
                        selection: .terminal(.init(rawValue: terminalUUID.uuidString))
                    )
                )
        )
    }

    @Test func resolvesPaneToItsRepresentedTerminalSurface() throws {
        let workspace = makeWorkspace()
        let resolver = MobileExternalNavigationTargetResolver(workspaces: [workspace])
        let request = try request(
            "\(scheme)://workspace/\(workspaceUUID.uuidString)/pane/\(paneUUID.uuidString)"
        )

        #expect(
            resolver.resolve(request)
                == .resolved(
                    .init(
                        workspaceID: workspace.id,
                        selection: .terminal(.init(rawValue: terminalUUID.uuidString))
                    )
                )
        )
    }

    @Test func resolvesDurableWorkspaceAndSurfaceIdentities() throws {
        let workspace = makeWorkspace()
        let resolver = MobileExternalNavigationTargetResolver(workspaces: [workspace])
        let workspaceRequest = try request(
            "\(scheme)://workspace/\(stableWorkspaceUUID.uuidString)"
        )
        let surfaceRequest = try request(
            "\(scheme)://workspace/\(stableWorkspaceUUID.uuidString)/surface/\(stableSurfaceUUID.uuidString)"
        )

        #expect(
            resolver.resolve(workspaceRequest)
                == .resolved(.init(workspaceID: workspace.id, selection: nil))
        )
        #expect(
            resolver.resolve(surfaceRequest)
                == .resolved(
                    .init(
                        workspaceID: workspace.id,
                        selection: .terminal(.init(rawValue: terminalUUID.uuidString))
                    )
                )
        )
    }

    @Test func defersWhenWorkspaceOrChildIsNotLoaded() throws {
        let workspace = makeWorkspace()
        let resolver = MobileExternalNavigationTargetResolver(workspaces: [workspace])
        let missingWorkspace = try request(
            "\(scheme)://workspace/44444444-4444-4444-4444-444444444444"
        )
        let missingSurface = try request(
            "\(scheme)://workspace/\(workspaceUUID.uuidString)/surface/55555555-5555-5555-5555-555555555555"
        )

        #expect(resolver.resolve(missingWorkspace) == .unavailable)
        #expect(resolver.resolve(missingSurface) == .unavailable)
    }

    private func makeWorkspace() -> MobileWorkspacePreview {
        let terminalID = MobileTerminalPreview.ID(rawValue: terminalUUID.uuidString)
        return MobileWorkspacePreview(
            id: .init(rawValue: workspaceUUID.uuidString),
            stableID: .init(rawValue: stableWorkspaceUUID.uuidString),
            name: "Workspace",
            terminals: [MobileTerminalPreview(id: terminalID, name: "Terminal")],
            surfaces: [
                MobileSurfacePreview(
                    id: .init(rawValue: terminalUUID.uuidString),
                    kind: .terminal,
                    title: "Terminal",
                    paneID: .init(rawValue: paneUUID.uuidString),
                    stableID: .init(rawValue: stableSurfaceUUID.uuidString)
                ),
            ]
        )
    }

    private func request(_ rawURL: String) throws -> CmxNavigationURLRequest {
        let url = try #require(URL(string: rawURL))
        switch CmxNavigationURLRequest.parse(url, supportedSchemes: [scheme]) {
        case .success(.some(let request)):
            return request
        case .success(nil):
            Issue.record("Expected navigation URL: \(rawURL)")
            throw TestError.invalidURL
        case .failure(let error):
            Issue.record("Unexpected parse error: \(error)")
            throw TestError.invalidURL
        }
    }

    private enum TestError: Error {
        case invalidURL
    }
}
