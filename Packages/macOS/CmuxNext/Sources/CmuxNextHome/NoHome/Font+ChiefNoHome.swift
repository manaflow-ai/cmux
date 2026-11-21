#if DEBUG
import CmuxNextDesign
import SwiftUI

/// DEBUG ONLY: the no-Home prototype's fonts, all from the type scale (TypeScale) through `Typography.system`.
extension Font {
    @MainActor static var noHomeBody: Font { Font(Typography.system(size: TypeScale.body)) }
    @MainActor static var noHomeBodyEmphasis: Font { Font(Typography.system(size: TypeScale.body, weight: TypeScale.emphasis)) }
    @MainActor static var noHomeCaption: Font { Font(Typography.system(size: TypeScale.caption)) }
    @MainActor static var noHomeCaptionEmphasis: Font { Font(Typography.system(size: TypeScale.caption, weight: TypeScale.emphasis)) }
    @MainActor static var noHomeCode: Font { Font(Typography.system(.monospaced, size: TypeScale.detail)) }
    @MainActor static var noHomeCodeCaption: Font { Font(Typography.system(.monospaced, size: TypeScale.caption)) }
    @MainActor static var noHomeGlyph: Font { Font(Typography.system(size: TypeScale.detail, weight: TypeScale.emphasis)) }
    @MainActor static var noHomeSend: Font { Font(Typography.system(size: TypeScale.heading)) }
}
#endif
