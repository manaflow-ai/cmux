import Foundation

/// The roles the first onboarding step offers ("Which best describes your
/// work?"), in the order the grid shows them, row by row.
public nonisolated enum OnboardingRole: String, CaseIterable, Codable, Sendable {
    case engineering, dataScience, product
    case design, marketing, sales
    case finance, operations, peopleAndHR
    case legal, student
}
