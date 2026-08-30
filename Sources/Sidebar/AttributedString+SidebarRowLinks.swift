import Foundation
import SwiftUI

extension AttributedString {
    /// Keeps only web destinations and gives selected-row links an explicit
    /// readable color. On unselected rows `inactiveLinkColor` quiets link runs
    /// to the surrounding text's tier and underlines them — the underline
    /// alone marks them — so link blue cannot outrank the row title.
    func applyingSidebarRowLinkPolicy(
        activeForegroundColor: Color?,
        inactiveLinkColor: Color? = nil
    ) -> AttributedString {
        transformingAttributes(
            \.link,
            \.foregroundColor,
            \.underlineStyle
        ) { link, foregroundColor, underlineStyle in
            guard let url = link.value else { return }
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                link.value = nil
                return
            }
            if let activeForegroundColor {
                foregroundColor.value = activeForegroundColor
            } else if let inactiveLinkColor {
                foregroundColor.value = inactiveLinkColor
                underlineStyle.value = .single
            }
        }
    }
}
