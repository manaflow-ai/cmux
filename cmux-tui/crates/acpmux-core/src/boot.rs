//! The system's boot, read once per process ("Files, per chat": a boot ends what was not synced).
//! A checkpoint written under another boot is opened as a changed stamp: cut at the mark, next
//! edition. Where the system gives no boot id, a value made once per process stands in, which is
//! right and only gives more fresh windows.

use std::sync::OnceLock;

/// The system's boot id as a `u64`: `/proc/sys/kernel/random/boot_id` on Linux,
/// `kern.bootsessionuuid` on macOS, else a random value made once in this process. Never 0, the
/// value of a config that names no boot.
pub fn system_boot_id() -> u64 {
    static BOOT: OnceLock<u64> = OnceLock::new();
    *BOOT.get_or_init(|| read_boot_uuid().map_or_else(process_value, |uuid| fold(&uuid)).max(1))
}

/// The hex digits of a UUID folded into 64 bits: its two halves XORed.
fn fold(uuid: &str) -> u64 {
    let digits: String = uuid.chars().filter(char::is_ascii_hexdigit).collect();
    let value = u128::from_str_radix(&digits, 16).unwrap_or(0);
    (value as u64) ^ ((value >> 64) as u64)
}

#[cfg(target_os = "linux")]
fn read_boot_uuid() -> Option<String> {
    let text = std::fs::read_to_string("/proc/sys/kernel/random/boot_id").ok()?;
    let text = text.trim();
    (text.chars().filter(char::is_ascii_hexdigit).count() == 32).then(|| text.to_owned())
}

#[cfg(target_os = "macos")]
fn read_boot_uuid() -> Option<String> {
    unsafe extern "C" {
        fn sysctlbyname(
            name: *const std::ffi::c_char,
            oldp: *mut std::ffi::c_void,
            oldlenp: *mut usize,
            newp: *mut std::ffi::c_void,
            newlen: usize,
        ) -> std::ffi::c_int;
    }
    let mut buffer = [0u8; 64];
    let mut length = buffer.len();
    // SAFETY: the name is a NUL-terminated literal, `buffer` is writable for `length` bytes and
    // the call writes at most that many, setting `length` to what it wrote. Nothing is set.
    let status = unsafe {
        sysctlbyname(
            c"kern.bootsessionuuid".as_ptr(),
            buffer.as_mut_ptr().cast(),
            &mut length,
            std::ptr::null_mut(),
            0,
        )
    };
    if status != 0 {
        return None;
    }
    let text = std::str::from_utf8(buffer.get(..length)?).ok()?.trim_end_matches('\0').trim();
    (text.chars().filter(char::is_ascii_hexdigit).count() == 32).then(|| text.to_owned())
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn read_boot_uuid() -> Option<String> {
    None
}

fn process_value() -> u64 {
    let mut bytes = [0u8; 8];
    if let Ok(mut random) = std::fs::File::open("/dev/urandom")
        && std::io::Read::read_exact(&mut random, &mut bytes).is_ok()
    {
        return u64::from_le_bytes(bytes);
    }
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos() as u64);
    nanos ^ u64::from(std::process::id()).rotate_left(32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_boot_id_is_read_once_and_is_never_zero() {
        let first = system_boot_id();
        assert_ne!(first, 0);
        assert_eq!(system_boot_id(), first);
        #[cfg(target_os = "linux")]
        {
            let uuid = std::fs::read_to_string("/proc/sys/kernel/random/boot_id").unwrap();
            assert_eq!(first, fold(uuid.trim()).max(1));
        }
    }

    #[test]
    fn a_uuid_folds_its_two_halves() {
        assert_eq!(fold("00000000-0000-0001-0000-000000000002"), 3);
        assert_eq!(fold("ffffffff-ffff-ffff-ffff-ffffffffffff"), 0);
    }
}
