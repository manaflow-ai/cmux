import CmuxNextDesign
import SwiftUI

/// A member's monogram disc in the group info sheet (an agent shows a sparkle instead of letters).
struct HomeGroupAvatar: View {
    let initials: String
    let isAgent: Bool
    let colors: HomeGroupInfoColors

    var body: some View {
        ZStack {
            Circle().fill(colors.hover)
            if isAgent {
                Image(systemName: "sparkles")
                    .font(Font(Typography.system(size: TypeScale.caption, weight: TypeScale.regular)))
                    .foregroundStyle(colors.secondary)
            } else {
                Text(initials)
                    .font(Font(Typography.system(size: TypeScale.caption, weight: TypeScale.emphasis)))
                    .foregroundStyle(colors.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
