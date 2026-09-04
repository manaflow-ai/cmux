import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct CmxNavigationURLRequestTests {
    private let scheme = "cmux-ios-test"
    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let paneID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let surfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let stableWorkspaceID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let stableSurfaceID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    @Test func parsesWorkspacePaneAndSurfaceRoutes() throws {
        let workspace = try #require(URL(string: "\(scheme)://workspace/\(workspaceID.uuidString)"))
        let pane = try #require(URL(string: "\(scheme)://workspace/\(workspaceID.uuidString)/pane/\(paneID.uuidString)"))
        let surface = try #require(URL(string: "\(scheme)://workspace/\(workspaceID.uuidString)/surface/\(surfaceID.uuidString)"))
        let panel = try #require(URL(string: "\(scheme)://workspace/\(workspaceID.uuidString)/panel/\(surfaceID.uuidString)"))

        #expect(try target(workspace) == .workspace(workspaceID))
        #expect(try target(pane) == .pane(workspaceId: workspaceID, paneId: paneID))
        #expect(try target(surface) == .surface(workspaceId: workspaceID, surfaceId: surfaceID))
        #expect(try target(panel) == .surface(workspaceId: workspaceID, surfaceId: surfaceID))
    }

    @Test func surfaceRoutesPreserveStableFallbacks() throws {
        let url = try #require(URL(string: CmxNavigationURLRequest.surfaceLink(
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            stableWorkspaceId: stableWorkspaceID,
            stableSurfaceId: stableSurfaceID,
            scheme: scheme
        )))

        let parsedRequest = try parsed(url)
        let request = try #require(parsedRequest)
        #expect(request.target == .surface(workspaceId: workspaceID, surfaceId: surfaceID))
        #expect(request.stableFallbackWorkspaceId == stableWorkspaceID)
        #expect(request.stableFallbackSurfaceId == stableSurfaceID)
    }

    @Test func ignoresOtherRoutesAndSchemes() throws {
        let sshURL = try #require(URL(string: "\(scheme)://ssh?host=example.com"))
        let foreignURL = try #require(URL(string: "cmux-other://workspace/\(workspaceID.uuidString)"))

        #expect(try parsedOptional(sshURL) == nil)
        #expect(try parsedOptional(foreignURL) == nil)
    }

    @Test func rejectsMalformedWorkspaceRoutes() throws {
        let cases = [
            ("\(scheme)://workspace/not-a-uuid", "workspace"),
            ("\(scheme)://workspace/\(workspaceID.uuidString)/pane/not-a-uuid", "pane"),
            ("\(scheme)://workspace/\(workspaceID.uuidString)/surface/not-a-uuid", "surface"),
        ]

        for (rawURL, component) in cases {
            let url = try #require(URL(string: rawURL))
            switch CmxNavigationURLRequest.parse(url, supportedSchemes: [scheme]) {
            case .failure(.invalidIdentifier(let value)):
                #expect(value == component)
            default:
                Issue.record("Expected invalid \(component) identifier rejection for \(rawURL)")
            }
        }
    }

    @Test func rejectsAuthorityFragmentsAndPaneQueries() throws {
        let cases = [
            "\(scheme)://user@workspace/\(workspaceID.uuidString)",
            "\(scheme)://workspace/\(workspaceID.uuidString)#fragment",
            "\(scheme)://workspace/\(workspaceID.uuidString)/pane/\(paneID.uuidString)?x=1",
            "\(scheme)://workspace/\(workspaceID.uuidString)/surface/\(surfaceID.uuidString)/extra",
        ]

        for rawURL in cases {
            let url = try #require(URL(string: rawURL))
            switch CmxNavigationURLRequest.parse(url, supportedSchemes: [scheme]) {
            case .failure(.unsupportedURLShape):
                break
            default:
                Issue.record("Expected unsupported URL shape rejection for \(rawURL)")
            }
        }
    }

    private func parsed(_ url: URL) throws -> CmxNavigationURLRequest? {
        switch CmxNavigationURLRequest.parse(url, supportedSchemes: [scheme]) {
        case .success(let request):
            return request
        case .failure(let error):
            throw error
        }
    }

    private func parsedOptional(_ url: URL) throws -> CmxNavigationURLRequest? {
        try parsed(url)
    }

    private func target(_ url: URL) throws -> CmxNavigationURLRequest.Target {
        try #require(parsed(url)?.target)
    }
}
