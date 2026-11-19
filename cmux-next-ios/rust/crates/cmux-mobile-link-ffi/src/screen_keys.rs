//! X11 keysyms and typed text as rd key events, for the iPhone's screen viewer.
//!
//! The phone's screen UI (CmuxScreenKit: the keyboard bar, the software keyboard, a hardware
//! keyboard read by HID usage) names keys as X11 keysyms, the way it has always spoken RFB. An
//! rd host takes USB HID usages (`0x0007_00ii`, a physical key), and the Linux host's XTest
//! path applies no committed text. This module maps a keysym to the key that types it on a US
//! layout, with Shift when that key needs it, so every keysym and every typed character the
//! phone sends reaches the host as key presses; a character no US key types goes as text.

use cmux_rd_proto::{InputEvent, MAX_TEXT_BYTES};

const PAGE: u32 = 0x0007_0000;
const LEFT_SHIFT: u32 = PAGE | 0xE1;
const RETURN: u32 = 0xFF0D;
const TAB: u32 = 0xFF09;

/// The HID usage of the key that types `keysym` on a US layout, and whether it needs Shift.
pub(crate) fn keysym_usage(keysym: u32) -> Option<(u32, bool)> {
    let id = |id: u32| Some((PAGE | id, false));
    let shifted = |id: u32| Some((PAGE | id, true));
    match keysym {
        // Letters: lower case bare, upper case with Shift.
        0x61..=0x7A => id(0x04 + keysym - 0x61),
        0x41..=0x5A => shifted(0x04 + keysym - 0x41),
        // Digits, and the symbols over them.
        0x31..=0x39 => id(0x1E + keysym - 0x31),
        0x30 => id(0x27),
        0x21 => shifted(0x1E), // !
        0x40 => shifted(0x1F), // @
        0x23 => shifted(0x20), // #
        0x24 => shifted(0x21), // $
        0x25 => shifted(0x22), // %
        0x5E => shifted(0x23), // ^
        0x26 => shifted(0x24), // &
        0x2A => shifted(0x25), // *
        0x28 => shifted(0x26), // (
        0x29 => shifted(0x27), // )
        0x20 => id(0x2C),
        0x2D => id(0x2D),
        0x5F => shifted(0x2D), // _
        0x3D => id(0x2E),
        0x2B => shifted(0x2E), // +
        0x5B => id(0x2F),
        0x7B => shifted(0x2F), // {
        0x5D => id(0x30),
        0x7D => shifted(0x30), // }
        0x5C => id(0x31),
        0x7C => shifted(0x31), // |
        0x3B => id(0x33),
        0x3A => shifted(0x33), // :
        0x27 => id(0x34),
        0x22 => shifted(0x34), // "
        0x60 => id(0x35),
        0x7E => shifted(0x35), // ~
        0x2C => id(0x36),
        0x3C => shifted(0x36), // <
        0x2E => id(0x37),
        0x3E => shifted(0x37), // >
        0x2F => id(0x38),
        0x3F => shifted(0x38), // ?
        // F1 to F12, F13 to F24.
        0xFFBE..=0xFFC9 => id(0x3A + keysym - 0xFFBE),
        0xFFCA..=0xFFD5 => id(0x68 + keysym - 0xFFCA),
        // Keypad 1 to 9.
        0xFFB1..=0xFFB9 => id(0x59 + keysym - 0xFFB1),
        _ => named_usage(keysym).map(|usage| (PAGE | usage, false)),
    }
}

/// Named keys: editing, navigation, keypad and modifiers.
fn named_usage(keysym: u32) -> Option<u32> {
    Some(match keysym {
        RETURN => 0x28,
        0xFF1B => 0x29,                   // Escape
        0xFF08 => 0x2A,                   // BackSpace
        TAB | 0xFE20 => 0x2B,             // Tab, ISO_Left_Tab
        0xFFE5 => 0x39,                   // Caps_Lock
        0xFF61 => 0x46,                   // Print
        0xFF14 => 0x47,                   // Scroll_Lock
        0xFF13 => 0x48,                   // Pause
        0xFF63 => 0x49,                   // Insert
        0xFF50 => 0x4A,                   // Home
        0xFF55 => 0x4B,                   // Page_Up
        0xFFFF => 0x4C,                   // Delete
        0xFF57 => 0x4D,                   // End
        0xFF56 => 0x4E,                   // Page_Down
        0xFF53 => 0x4F,                   // Right
        0xFF51 => 0x50,                   // Left
        0xFF54 => 0x51,                   // Down
        0xFF52 => 0x52,                   // Up
        0xFF7F => 0x53,                   // Num_Lock
        0xFFAF => 0x54,                   // KP_Divide
        0xFFAA => 0x55,                   // KP_Multiply
        0xFFAD => 0x56,                   // KP_Subtract
        0xFFAB => 0x57,                   // KP_Add
        0xFF8D => 0x58,                   // KP_Enter
        0xFFB0 => 0x62,                   // KP_0
        0xFFAE => 0x63,                   // KP_Decimal
        0xFF67 => 0x65,                   // Menu
        0xFFBD => 0x67,                   // KP_Equal
        0xFF6A => 0x75,                   // Help
        0xFFE3 => 0xE0,                   // Control_L
        0xFFE1 => 0xE1,                   // Shift_L
        0xFFE9 | 0xFFE7 => 0xE2,          // Alt_L, Meta_L
        0xFFEB => 0xE3,                   // Super_L (Command on a Mac)
        0xFFE4 => 0xE4,                   // Control_R
        0xFFE2 => 0xE5,                   // Shift_R
        0xFFEA | 0xFFE8 | 0xFE03 => 0xE6, // Alt_R, Meta_R, ISO_Level3_Shift
        0xFFEC => 0xE7,                   // Super_R
        _ => return None,
    })
}

/// The character a keysym stands for, when it is one: Latin-1 directly, the rest of Unicode
/// in the `0x0100_0000` plane.
fn keysym_char(keysym: u32) -> Option<char> {
    match keysym {
        0x20..=0x7E | 0xA0..=0xFF => char::from_u32(keysym),
        0x0100_0000..=0x0110_FFFF => char::from_u32(keysym - 0x0100_0000),
        _ => None,
    }
}

/// The keysym that types `c` (what CmuxScreenKit's `VNCKeysym(character:)` makes).
fn char_keysym(c: char) -> u32 {
    match c {
        '\n' | '\r' => RETURN,
        '\t' => TAB,
        c if u32::from(c) <= 0xFF => u32::from(c),
        c => 0x0100_0000 | u32::from(c),
    }
}

/// One keysym going down or up: its key (with Shift around it when the key needs it), or
/// for a character no US key types, the character as text when it goes down.
pub(crate) fn keysym_events(keysym: u32, down: bool) -> Result<Vec<InputEvent>, String> {
    if let Some((usage, shift)) = keysym_usage(keysym) {
        let key = InputEvent::Key { usage, down };
        let shift_key = InputEvent::Key { usage: LEFT_SHIFT, down };
        return Ok(match (shift, down) {
            (false, _) => vec![key],
            (true, true) => vec![shift_key, key],
            (true, false) => vec![key, shift_key],
        });
    }
    match keysym_char(keysym) {
        Some(c) if down => Ok(vec![InputEvent::Text(c.to_string())]),
        Some(_) => Ok(Vec::new()),
        None => Err(format!("no key types keysym {keysym:#x}")),
    }
}

/// Typed text as key presses (each character down and up); runs of characters no US key types
/// go as text, at most [`MAX_TEXT_BYTES`] each.
pub(crate) fn typed_events(text: &str) -> Vec<InputEvent> {
    let mut events = Vec::new();
    let mut run = String::new();
    let flush = |run: &mut String, events: &mut Vec<InputEvent>| {
        if !run.is_empty() {
            events.push(InputEvent::Text(std::mem::take(run)));
        }
    };
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        // "\r\n" is one Return.
        if c == '\r' && chars.peek() == Some(&'\n') {
            continue;
        }
        match keysym_usage(char_keysym(c)) {
            Some(_) => {
                flush(&mut run, &mut events);
                for down in [true, false] {
                    events.extend(keysym_events(char_keysym(c), down).unwrap_or_default());
                }
            }
            None => {
                if run.len() + c.len_utf8() > MAX_TEXT_BYTES {
                    flush(&mut run, &mut events);
                }
                run.push(c);
            }
        }
    }
    flush(&mut run, &mut events);
    events
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(id: u32, down: bool) -> InputEvent {
        InputEvent::Key { usage: PAGE | id, down }
    }

    #[test]
    fn keysyms_become_us_layout_keys() {
        assert_eq!(keysym_usage(0x61), Some((PAGE | 0x04, false))); // a
        assert_eq!(keysym_usage(0x41), Some((PAGE | 0x04, true))); // A
        assert_eq!(keysym_usage(0x30), Some((PAGE | 0x27, false))); // 0
        assert_eq!(keysym_usage(0x3F), Some((PAGE | 0x38, true))); // ?
        assert_eq!(keysym_usage(0xFF0D), Some((PAGE | 0x28, false))); // Return
        assert_eq!(keysym_usage(0xFFBE), Some((PAGE | 0x3A, false))); // F1
        assert_eq!(keysym_usage(0xFFD5), Some((PAGE | 0x73, false))); // F24
        assert_eq!(keysym_usage(0xFFEB), Some((PAGE | 0xE3, false))); // Super_L
        assert_eq!(keysym_usage(0xE9), None); // é: no US key
    }

    /// Every key CmuxScreenKit's `VNCKeysym(hidUsage:)` names maps back to that key, so a
    /// hardware keyboard's presses reach the host as the keys pressed.
    #[test]
    fn hardware_keys_round_trip() {
        let swift_table: &[(u32, u32)] = &[
            (0x28, 0xFF0D),
            (0x29, 0xFF1B),
            (0x2A, 0xFF08),
            (0x2B, 0xFF09),
            (0x2C, 0x20),
            (0x2D, 0x2D),
            (0x2E, 0x3D),
            (0x2F, 0x5B),
            (0x30, 0x5D),
            (0x31, 0x5C),
            (0x33, 0x3B),
            (0x34, 0x27),
            (0x35, 0x60),
            (0x36, 0x2C),
            (0x37, 0x2E),
            (0x38, 0x2F),
            (0x39, 0xFFE5),
            (0x46, 0xFF61),
            (0x47, 0xFF14),
            (0x48, 0xFF13),
            (0x49, 0xFF63),
            (0x4A, 0xFF50),
            (0x4B, 0xFF55),
            (0x4C, 0xFFFF),
            (0x4D, 0xFF57),
            (0x4E, 0xFF56),
            (0x4F, 0xFF53),
            (0x50, 0xFF51),
            (0x51, 0xFF54),
            (0x52, 0xFF52),
            (0x53, 0xFF7F),
            (0x54, 0xFFAF),
            (0x55, 0xFFAA),
            (0x56, 0xFFAD),
            (0x57, 0xFFAB),
            (0x58, 0xFF8D),
            (0x62, 0xFFB0),
            (0x63, 0xFFAE),
            (0x67, 0xFFBD),
            (0x75, 0xFF6A),
            (0xE0, 0xFFE3),
            (0xE1, 0xFFE1),
            (0xE2, 0xFFE9),
            (0xE3, 0xFFEB),
            (0xE4, 0xFFE4),
            (0xE5, 0xFFE2),
            (0xE6, 0xFFEA),
            (0xE7, 0xFFEC),
        ];
        for &(id, keysym) in swift_table {
            assert_eq!(keysym_usage(keysym), Some((PAGE | id, false)), "keysym {keysym:#x}");
        }
        for id in 0x04..=0x1D {
            assert_eq!(keysym_usage(0x61 + id - 0x04), Some((PAGE | id, false)));
        }
        for id in 0x1E..=0x26 {
            assert_eq!(keysym_usage(0x31 + id - 0x1E), Some((PAGE | id, false)));
        }
        for id in (0x3A..=0x45).chain(0x68..=0x73).chain(0x59..=0x61) {
            let keysym = match id {
                0x3A..=0x45 => 0xFFBE + id - 0x3A,
                0x68..=0x73 => 0xFFCA + id - 0x68,
                _ => 0xFFB1 + id - 0x59,
            };
            assert_eq!(keysym_usage(keysym), Some((PAGE | id, false)), "usage {id:#x}");
        }
    }

    #[test]
    fn a_shifted_keysym_holds_shift_around_its_key() {
        assert_eq!(keysym_events(0x41, true).unwrap(), vec![key(0xE1, true), key(0x04, true)]);
        assert_eq!(keysym_events(0x41, false).unwrap(), vec![key(0x04, false), key(0xE1, false)]);
        assert_eq!(keysym_events(0xFF08, true).unwrap(), vec![key(0x2A, true)]);
        // A character no key types goes as text, once.
        assert_eq!(keysym_events(0x0100_4E2D, true).unwrap(), vec![InputEvent::Text("中".into())]);
        assert!(keysym_events(0x0100_4E2D, false).unwrap().is_empty());
        assert!(keysym_events(0xFE50, true).is_err(), "a dead key has no key here");
    }

    #[test]
    fn typed_text_becomes_key_presses() {
        assert_eq!(
            typed_events("Hi\r\n"),
            vec![
                key(0xE1, true),
                key(0x0B, true),
                key(0x0B, false),
                key(0xE1, false),
                key(0x0C, true),
                key(0x0C, false),
                key(0x28, true),
                key(0x28, false),
            ]
        );
        assert_eq!(
            typed_events("a中文b"),
            vec![
                key(0x04, true),
                key(0x04, false),
                InputEvent::Text("中文".into()),
                key(0x05, true),
                key(0x05, false),
            ]
        );
        let long = "é".repeat(200);
        let events = typed_events(&long);
        assert_eq!(events.len(), 2, "400 bytes of text in two events");
        assert!(events.iter().all(|e| matches!(e, InputEvent::Text(t) if t.len() <= MAX_TEXT_BYTES)));
    }
}
