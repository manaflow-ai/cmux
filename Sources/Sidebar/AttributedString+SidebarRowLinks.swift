import Foundation
import SwiftUI

extension AttributedString {
    /// Keeps only web destinations and gives selected-row links an explicit readable color.
    func applyingSidebarRowLinkPolicy(activeForegroundColor: Color?) -> AttributedString {
        transformingAttributes(
            \.link,
            \.foregroundColor
        ) { link, foregroundColor in
            guard let url = link.value else { return }
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                link.value = nil
                return
            }
            if let activeForegroundColor {
                foregroundColor.value = activeForegroundColor
            }
        }
    }
}
