import Foundation

/// Test seam for classification; implementations perform all engine I/O off the main actor.
protocol SidebarOrganizationAnalyzing: Sendable {
    func prepare(_ input: SidebarOrganizationInput) async throws -> SidebarOrganizationInput
    func analyze(_ input: SidebarOrganizationInput, review: Data?) async throws -> SidebarOrganizationOutput
}

extension SidebarOrganizationAnalyzing {
    func prepare(_ input: SidebarOrganizationInput) async throws -> SidebarOrganizationInput { input }
}
