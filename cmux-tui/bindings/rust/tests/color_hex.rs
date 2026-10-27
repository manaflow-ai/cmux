//! `ColorHex` decodes its channels when it is validated, so a renderer reads them without
//! parsing (and without a panic path) again.

use cmux::ColorHex;

#[test]
fn a_color_decodes_its_channels_when_parsed() {
    let color = ColorHex::parse("#0a7fff").expect("lowercase #rrggbb");
    assert_eq!(color.as_str(), "#0a7fff");
    assert_eq!(color.rgb(), [0x0a, 0x7f, 0xff]);
}

#[test]
fn only_lowercase_six_digit_hex_is_a_color() {
    // "#+a7fff" would pass u8::from_str_radix's sign rule; "#é7fff" is seven bytes long.
    for bad in ["#0A7FFF", "0a7fff", "#0a7ff", "#0a7fffa", "#+a7fff", "#é7fff", ""] {
        assert!(ColorHex::parse(bad).is_err(), "{bad:?} is not a color");
    }
}
