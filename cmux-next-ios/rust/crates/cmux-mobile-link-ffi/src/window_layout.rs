//! How the phone's window is laid out at a size: one pane, or a list beside
//! its detail. A foldable iPhone resizes the window live, from a phone's
//! screen folded to a nearly square one unfolded and back, so this is a pure
//! function of the window's size in points that Swift asks on every size
//! change and only renders. The thresholds are cmuxterm-hq
//! `docs/design/ios-foldable.md`'s.
//!
//! Every size between a compact iPhone and an unfolded, nearly square screen
//! gets an answer; nothing here knows a device model.

/// A window whose shorter side is at least this is an unfolded foldable's
/// (or an iPad's). No shipping iPhone's shorter side reaches it: the largest
/// is 440 pt. The same threshold as the app's orientation rule
/// (`ScreenSharingOrientation.unfoldedShortSide`).
pub const UNFOLDED_SHORT_SIDE: f64 = 600.0;

/// An unfolded window at least this wide shows a list beside its detail.
/// Below it the detail would be narrower than a compact phone (~375 pt) once
/// the list takes its minimum. An iPad mini in portrait (744 pt) and an
/// unfolded foldable (reported around 4:3, assumed at least 720 pt wide) pass.
pub const TWO_PANE_MIN_WIDTH: f64 = 700.0;

/// The list column's share of the window, and its bounds.
const LIST_SHARE: f64 = 0.36;
const LIST_MIN_WIDTH: f64 = 300.0;
const LIST_MAX_WIDTH: f64 = 380.0;

/// A tab overview card is at least this wide; the overview shows as many
/// columns as fit, between two and four.
const OVERVIEW_MIN_CARD: f64 = 200.0;
const OVERVIEW_MIN_COLUMNS: u32 = 2;
const OVERVIEW_MAX_COLUMNS: u32 = 4;

/// The window's layout at one size.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct WindowLayout {
    /// The shorter side reaches [`UNFOLDED_SHORT_SIDE`]: the window turns
    /// with the phone, as an iPad's does.
    pub unfolded: bool,
    /// A list beside its detail (Home's chats beside the open chat,
    /// Workspaces' list beside the open workspace).
    pub two_pane: bool,
    /// The list column's width in points; the whole width with one pane.
    pub list_width: f64,
    /// The detail's width in points (the window less the list and its
    /// divider); the whole width with one pane.
    pub detail_width: f64,
    /// Columns of the tab overview at the detail's width.
    pub overview_columns: u32,
}

/// Width of the line between the two panes, in points.
pub const DIVIDER_WIDTH: f64 = 1.0;

/// The layout of a window `width` by `height` points. A size that is not
/// finite or not positive is a compact phone's of that width (zero when
/// unknown), so a transient zero size during a scene change never shows two
/// panes.
#[uniffi::export]
pub fn window_layout(width: f64, height: f64) -> WindowLayout {
    let width = sane(width);
    let height = sane(height);
    let unfolded = width.min(height) >= UNFOLDED_SHORT_SIDE;
    let two_pane = unfolded && width >= TWO_PANE_MIN_WIDTH;
    let (list_width, detail_width) = if two_pane {
        let list = (width * LIST_SHARE).round().clamp(LIST_MIN_WIDTH, LIST_MAX_WIDTH);
        (list, width - list - DIVIDER_WIDTH)
    } else {
        (width, width)
    };
    WindowLayout {
        unfolded,
        two_pane,
        list_width,
        detail_width,
        overview_columns: overview_columns(detail_width),
    }
}

/// Columns of the tab overview in a page `width` points wide: as many
/// [`OVERVIEW_MIN_CARD`]-wide cards as fit, two to four.
#[uniffi::export]
pub fn overview_columns(width: f64) -> u32 {
    let fit = (sane(width) / OVERVIEW_MIN_CARD).floor();
    // A non-negative whole number of at most OVERVIEW_MAX_COLUMNS: the cast is exact.
    let fit = fit.min(f64::from(OVERVIEW_MAX_COLUMNS)) as u32;
    fit.clamp(OVERVIEW_MIN_COLUMNS, OVERVIEW_MAX_COLUMNS)
}

fn sane(value: f64) -> f64 {
    if value.is_finite() && value > 0.0 { value } else { 0.0 }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Window sizes in points: measured from Apple's published simulator
    /// sizes, except the foldable's, which are assumed from reports.
    const IPHONE_SE: (f64, f64) = (375.0, 667.0);
    const IPHONE_17_PRO: (f64, f64) = (402.0, 874.0);
    const IPHONE_17_PRO_MAX: (f64, f64) = (440.0, 956.0);
    const IPAD_MINI: (f64, f64) = (744.0, 1133.0);
    const FOLD_OUTER_ASSUMED: (f64, f64) = (390.0, 844.0);
    const FOLD_INNER_ASSUMED: (f64, f64) = (744.0, 992.0);

    #[test]
    fn every_phone_is_one_pane_and_portrait() {
        for (w, h) in [IPHONE_SE, IPHONE_17_PRO, IPHONE_17_PRO_MAX, FOLD_OUTER_ASSUMED] {
            let layout = window_layout(w, h);
            assert!(!layout.unfolded, "{w}x{h}");
            assert!(!layout.two_pane, "{w}x{h}");
            assert_eq!(layout.list_width, w);
            assert_eq!(layout.detail_width, w);
            assert_eq!(layout.overview_columns, 2, "{w}x{h}");
        }
    }

    #[test]
    fn a_landscape_phone_stays_one_pane() {
        let layout = window_layout(IPHONE_17_PRO_MAX.1, IPHONE_17_PRO_MAX.0);
        assert!(!layout.unfolded);
        assert!(!layout.two_pane);
        assert_eq!(layout.overview_columns, 4);
    }

    #[test]
    fn unfolded_portrait_shows_two_panes() {
        for (w, h) in [IPAD_MINI, FOLD_INNER_ASSUMED] {
            let layout = window_layout(w, h);
            assert!(layout.unfolded);
            assert!(layout.two_pane);
            assert_eq!(layout.list_width, 300.0);
            assert_eq!(layout.detail_width, w - 301.0);
            assert_eq!(layout.overview_columns, 2);
        }
    }

    #[test]
    fn unfolded_landscape_gives_the_detail_more_columns() {
        let layout = window_layout(FOLD_INNER_ASSUMED.1, FOLD_INNER_ASSUMED.0);
        assert!(layout.two_pane);
        assert_eq!(layout.list_width, 357.0);
        assert_eq!(layout.detail_width, 992.0 - 358.0);
        assert_eq!(layout.overview_columns, 3);
        let wide = window_layout(1400.0, 1000.0);
        assert_eq!(wide.list_width, LIST_MAX_WIDTH);
        assert_eq!(wide.overview_columns, 4);
    }

    #[test]
    fn a_square_window_too_narrow_for_two_panes_is_one_unfolded_pane() {
        let layout = window_layout(650.0, 650.0);
        assert!(layout.unfolded);
        assert!(!layout.two_pane);
        assert_eq!(layout.detail_width, 650.0);
        assert_eq!(layout.overview_columns, 3);
    }

    #[test]
    fn the_detail_never_gets_narrower_than_a_compact_phone() {
        let mut w = TWO_PANE_MIN_WIDTH;
        while w <= 1400.0 {
            let layout = window_layout(w, 1000.0);
            assert!(layout.two_pane);
            assert!(layout.detail_width >= 375.0, "{w}: {}", layout.detail_width);
            assert!((layout.list_width + DIVIDER_WIDTH + layout.detail_width - w).abs() < 1e-9);
            w += 1.0;
        }
    }

    /// A live fold walks every width; the decision changes exactly once each
    /// way, at the threshold, so a resize mid-gesture cannot flicker.
    #[test]
    fn a_live_resize_crosses_two_panes_once_each_way() {
        let widths: Vec<f64> = (390..=744).chain((390..=744).rev()).map(f64::from).collect();
        let flips = widths
            .windows(2)
            .filter(|pair| window_layout(pair[0], 992.0).two_pane != window_layout(pair[1], 992.0).two_pane)
            .count();
        assert_eq!(flips, 2);
    }

    #[test]
    fn an_unknown_size_is_one_pane() {
        for (w, h) in
            [(0.0, 0.0), (f64::NAN, 900.0), (-10.0, 900.0), (f64::INFINITY, f64::INFINITY), (900.0, 0.0)]
        {
            let layout = window_layout(w, h);
            assert!(!layout.two_pane, "{w}x{h}");
            assert!(!layout.unfolded, "{w}x{h}");
            assert_eq!(layout.overview_columns, 2);
        }
    }
}
