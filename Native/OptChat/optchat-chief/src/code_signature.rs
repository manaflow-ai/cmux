//! The code signature of an acpmux peer whose executable is gone (cx-ggai,
//! the moved-acpmux rule).
//!
//! An app update (Sparkle) moves the old bundle away and deletes it while the
//! Chief home's shared acpmux keeps running from it. `proc_pidpath` then has
//! no path, so the path rule of `acpmux_peer` cannot name the peer, and every
//! new brain refused it (2026-10-23: Muse Chief, pid 43389). Security's
//! `SecCode` cannot open such a process either (it reads the file: ENOENT).
//!
//! The kernel still holds the signature it validated the process's pages
//! against. So for a peer whose executable is gone, `acpmux_peer` accepts it
//! only when all of these hold, read through the socket's audit token
//! (`csops_audittoken`, no pid reuse):
//!
//! - the kernel marks its code valid and not ad hoc;
//! - the kernel's cdhash is the SHA-256 of the signature's CodeDirectory, so
//!   the blob below is the one the kernel enforces;
//! - the CMS signature over that CodeDirectory verifies, and its certificate
//!   chain ends at Apple Root CA (`anchor apple generic`);
//! - that chain is valid at the signature's secure timestamp (RFC 3161, the
//!   one Apple's notary requires), else at the current time: a timestamped
//!   signature stays valid after its certificate expires, as macOS treats it;
//!   one without a secure timestamp does not. The CMS `signingTime` attribute
//!   is the signer's own claim and never moves that time;
//! - the signing certificate's OU, the CodeDirectory's team ID and its
//!   identifier are the team ID and identifier of the acpmux this host runs
//!   ([`of_file`], itself Apple-anchored).
//!
//! Anything else is refused. On other systems nothing is accepted this way.

/// The signature the kernel enforces on a running process.
#[derive(Debug, Clone)]
pub struct KernelSignature {
    /// `CS_OPS_STATUS` flags (`CS_VALID`, `CS_ADHOC`, ...).
    pub flags: u32,
    /// `CS_OPS_CDHASH`: the first 20 bytes of the CodeDirectory's hash.
    pub cdhash: [u8; 20],
    /// `CS_OPS_BLOB`: the embedded signature SuperBlob.
    pub blob: Vec<u8>,
}

/// Who signed a binary: its team ID and signing identifier.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signer {
    pub team: String,
    pub identifier: String,
}

const CS_VALID: u32 = 0x1;
const CS_ADHOC: u32 = 0x2;
const SUPERBLOB_MAGIC: usize = 0xfade_0cc0;
const CODEDIRECTORY_MAGIC: usize = 0xfade_0c02;
const CMS_MAGIC: usize = 0xfade_0b01;
const SLOT_CODEDIRECTORY: usize = 0;
const SLOT_CMS: usize = 0x10000;
const HASH_SHA256: u8 = 2;
/// SHA-256 of Apple Root CA's certificate (the `anchor apple` root).
#[cfg(target_os = "macos")]
const APPLE_ROOT_CA_SHA256: &str =
    "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024";

/// Checks `signature` (a running process's) against `ours` (see the module
/// doc) now; the error says which rule failed.
pub fn verify(signature: &KernelSignature, ours: &Signer) -> Result<(), String> {
    verify_at(signature, ours, std::time::SystemTime::now())
}

/// [`verify`], with `now` as the current time: the time its certificate
/// chain must be valid at when the signature has no secure timestamp.
pub fn verify_at(
    signature: &KernelSignature,
    ours: &Signer,
    now: std::time::SystemTime,
) -> Result<(), String> {
    use sha2::Digest as _;
    if signature.flags & CS_VALID == 0 {
        return Err("the kernel does not mark its code valid".into());
    }
    if signature.flags & CS_ADHOC != 0 {
        return Err("its code is signed ad hoc".into());
    }
    let (directory, cms) = parse(&signature.blob)?;
    if directory.get(37) != Some(&HASH_SHA256) {
        return Err("its CodeDirectory is not SHA-256".into());
    }
    let hash = sha2::Sha256::digest(directory);
    if hash[..20] != signature.cdhash {
        return Err("its signature blob is not the code the kernel runs (cdhash)".into());
    }
    let identifier = c_string_at(directory, be32(directory, 20)?)?;
    if be32(directory, 8)? < 0x20200 {
        return Err("its CodeDirectory has no team ID".into());
    }
    let team = c_string_at(directory, be32(directory, 48)?)?;
    if identifier != ours.identifier {
        return Err(format!(
            "it is signed as {identifier:?}, not {:?}",
            ours.identifier
        ));
    }
    if team != ours.team {
        return Err(format!("its team is {team:?}, not {:?}", ours.team));
    }
    let leaf_team = cms_signer_team(cms, directory, now)?;
    if leaf_team != ours.team {
        return Err(format!(
            "its signing certificate's team (OU) is {leaf_team:?}, not {:?}",
            ours.team
        ));
    }
    Ok(())
}

/// The CodeDirectory and the CMS signature of a SuperBlob.
fn parse(blob: &[u8]) -> Result<(&[u8], &[u8]), String> {
    if be32(blob, 0)? != SUPERBLOB_MAGIC {
        return Err("its signature is not a SuperBlob".into());
    }
    let count = be32(blob, 8)?;
    let (mut directory, mut cms) = (None, None);
    for i in 0..count {
        let entry = 12 + 8 * i;
        let (slot, offset) = (be32(blob, entry)?, be32(blob, entry + 4)?);
        let magic = be32(blob, offset)?;
        let length = be32(blob, offset + 4)?;
        let end = offset.checked_add(length).ok_or("bad blob length")?;
        let bytes = blob
            .get(offset..end)
            .ok_or("a blob runs past the signature")?;
        match (slot, magic) {
            (SLOT_CODEDIRECTORY, CODEDIRECTORY_MAGIC) => directory = Some(bytes),
            (SLOT_CMS, CMS_MAGIC) => cms = bytes.get(8..),
            _ => {}
        }
    }
    match (directory, cms) {
        (Some(d), Some(c)) if !c.is_empty() => Ok((d, c)),
        (None, _) => Err("its signature has no CodeDirectory".into()),
        _ => Err("its signature has no CMS signature".into()),
    }
}

fn be32(bytes: &[u8], at: usize) -> Result<usize, String> {
    let b = bytes.get(at..at + 4).ok_or("the signature is truncated")?;
    Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as usize)
}

fn c_string_at(bytes: &[u8], at: usize) -> Result<String, String> {
    let rest = bytes
        .get(at..)
        .ok_or("a string runs past the CodeDirectory")?;
    let end = rest
        .iter()
        .position(|&b| b == 0)
        .ok_or("an unterminated string in the CodeDirectory")?;
    String::from_utf8(rest[..end].to_vec()).map_err(|_| "a string that is not UTF-8".into())
}

#[cfg(target_os = "macos")]
pub use macos::{of_file, running_peer};

#[cfg(not(target_os = "macos"))]
fn cms_signer_team(_: &[u8], _: &[u8], _: std::time::SystemTime) -> Result<String, String> {
    Err("code signatures are checked on macOS only".into())
}

/// The kernel's signature of the server peer of `stream` (macOS only).
#[cfg(not(target_os = "macos"))]
pub fn running_peer(_: &std::os::unix::net::UnixStream) -> Result<KernelSignature, String> {
    Err("code signatures are checked on macOS only".into())
}

/// The Apple-anchored signer of the binary at `path` (macOS only).
#[cfg(not(target_os = "macos"))]
pub fn of_file(_: &std::path::Path) -> Result<Signer, String> {
    Err("code signatures are checked on macOS only".into())
}

#[cfg(target_os = "macos")]
use macos::cms_signer_team;

#[cfg(target_os = "macos")]
mod macos {
    use super::{APPLE_ROOT_CA_SHA256, KernelSignature, Signer};
    use std::ffi::c_void;
    use std::os::unix::io::AsRawFd;
    use std::os::unix::net::UnixStream;
    use std::path::Path;

    type CFTypeRef = *const c_void;
    type OSStatus = i32;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(cf: CFTypeRef);
        fn CFEqual(a: CFTypeRef, b: CFTypeRef) -> u8;
        fn CFGetTypeID(cf: CFTypeRef) -> usize;
        fn CFStringGetTypeID() -> usize;
        fn CFArrayGetTypeID() -> usize;
        fn CFDictionaryGetTypeID() -> usize;
        fn CFDataCreate(alloc: CFTypeRef, bytes: *const u8, len: isize) -> CFTypeRef;
        fn CFDateCreate(alloc: CFTypeRef, at: f64) -> CFTypeRef;
        fn CFErrorGetCode(error: CFTypeRef) -> isize;
        fn CFDataGetBytePtr(data: CFTypeRef) -> *const u8;
        fn CFDataGetLength(data: CFTypeRef) -> isize;
        fn CFArrayGetCount(array: CFTypeRef) -> isize;
        fn CFArrayGetValueAtIndex(array: CFTypeRef, index: isize) -> CFTypeRef;
        fn CFDictionaryGetValue(dict: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
        fn CFStringCreateWithBytes(
            alloc: CFTypeRef,
            bytes: *const u8,
            len: isize,
            encoding: u32,
            external: u8,
        ) -> CFTypeRef;
        fn CFStringGetCString(s: CFTypeRef, buf: *mut u8, size: isize, encoding: u32) -> u8;
        fn CFURLCreateFromFileSystemRepresentation(
            alloc: CFTypeRef,
            path: *const u8,
            len: isize,
            is_directory: u8,
        ) -> CFTypeRef;
    }

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        static kSecOIDX509V1SubjectName: CFTypeRef;
        static kSecOIDOrganizationalUnitName: CFTypeRef;
        static kSecPropertyKeyValue: CFTypeRef;
        static kSecPropertyKeyLabel: CFTypeRef;
        static kSecCodeInfoIdentifier: CFTypeRef;
        static kSecCodeInfoTeamIdentifier: CFTypeRef;
        fn CMSDecoderCreate(out: *mut CFTypeRef) -> OSStatus;
        fn CMSDecoderUpdateMessage(d: CFTypeRef, bytes: *const u8, len: usize) -> OSStatus;
        fn CMSDecoderSetDetachedContent(d: CFTypeRef, content: CFTypeRef) -> OSStatus;
        fn CMSDecoderFinalizeMessage(d: CFTypeRef) -> OSStatus;
        fn CMSDecoderGetNumSigners(d: CFTypeRef, out: *mut usize) -> OSStatus;
        fn CMSDecoderCopySignerStatus(
            d: CFTypeRef,
            index: usize,
            policy: CFTypeRef,
            evaluate_trust: u8,
            status: *mut u32,
            trust: *mut CFTypeRef,
            cert_verify_result: *mut OSStatus,
        ) -> OSStatus;
        static kSecPolicyAppleTimeStamping: CFTypeRef;
        fn CMSDecoderCopySignerTimestampWithPolicy(
            d: CFTypeRef,
            policy: CFTypeRef,
            index: usize,
            timestamp: *mut f64,
        ) -> OSStatus;
        fn SecPolicyCreateWithProperties(kind: CFTypeRef, properties: CFTypeRef) -> CFTypeRef;
        fn SecPolicyCreateBasicX509() -> CFTypeRef;
        fn SecTrustSetVerifyDate(trust: CFTypeRef, date: CFTypeRef) -> OSStatus;
        fn SecTrustEvaluateWithError(trust: CFTypeRef, error: *mut CFTypeRef) -> bool;
        fn SecTrustCopyCertificateChain(trust: CFTypeRef) -> CFTypeRef;
        fn SecCertificateCopyData(cert: CFTypeRef) -> CFTypeRef;
        fn SecCertificateCopyValues(
            cert: CFTypeRef,
            keys: CFTypeRef,
            error: *mut CFTypeRef,
        ) -> CFTypeRef;
        fn SecStaticCodeCreateWithPath(url: CFTypeRef, flags: u32, out: *mut CFTypeRef)
        -> OSStatus;
        fn SecRequirementCreateWithString(
            text: CFTypeRef,
            flags: u32,
            out: *mut CFTypeRef,
        ) -> OSStatus;
        fn SecStaticCodeCheckValidity(code: CFTypeRef, flags: u32, req: CFTypeRef) -> OSStatus;
        fn SecCodeCopySigningInformation(
            code: CFTypeRef,
            flags: u32,
            out: *mut CFTypeRef,
        ) -> OSStatus;
    }

    unsafe extern "C" {
        /// libSystem: the kernel's code signing state of the process the
        /// audit token names (fails when the pid was reused).
        fn csops_audittoken(
            pid: i32,
            ops: u32,
            buf: *mut c_void,
            size: usize,
            token: *const [u32; 8],
        ) -> i32;
    }

    const UTF8: u32 = 0x0800_0100;
    /// Seconds from the Unix epoch to Core Foundation's (2001-01-01 UTC).
    const CF_EPOCH: f64 = 978_307_200.0;
    const CMS_SIGNER_VALID: u32 = 1;
    const SIGNING_INFORMATION: u32 = 1 << 1;
    const CS_OPS_STATUS: u32 = 0;
    const CS_OPS_CDHASH: u32 = 5;
    const CS_OPS_BLOB: u32 = 10;
    const SOL_LOCAL: libc::c_int = 0;
    const LOCAL_PEERTOKEN: libc::c_int = 0x006;

    /// An owned Core Foundation reference (released on drop).
    struct Cf(CFTypeRef);

    impl Cf {
        fn new(r: CFTypeRef, what: &str) -> Result<Cf, String> {
            if r.is_null() {
                Err(format!("{what} failed"))
            } else {
                Ok(Cf(r))
            }
        }
    }

    impl Drop for Cf {
        fn drop(&mut self) {
            // SAFETY: self.0 is a non-null reference this value owns.
            unsafe { CFRelease(self.0) }
        }
    }

    fn data(bytes: &[u8]) -> Result<Cf, String> {
        // SAFETY: bytes is valid for its length; CFDataCreate copies it.
        Cf::new(
            unsafe { CFDataCreate(std::ptr::null(), bytes.as_ptr(), bytes.len() as isize) },
            "CFDataCreate",
        )
    }

    fn bytes_of(data: CFTypeRef) -> Vec<u8> {
        // SAFETY: data is a CFData; the pointer is valid for its length while it lives.
        unsafe {
            std::slice::from_raw_parts(CFDataGetBytePtr(data), CFDataGetLength(data) as usize)
                .to_vec()
        }
    }

    fn string_of(s: CFTypeRef) -> Option<String> {
        // SAFETY: CFGetTypeID accepts any CF object; s is checked to be a CFString.
        if s.is_null() || unsafe { CFGetTypeID(s) != CFStringGetTypeID() } {
            return None;
        }
        let mut buf = vec![0u8; 1024];
        // SAFETY: buf is valid for its length.
        if unsafe { CFStringGetCString(s, buf.as_mut_ptr(), buf.len() as isize, UTF8) } == 0 {
            return None;
        }
        let end = buf.iter().position(|&b| b == 0)?;
        String::from_utf8(buf[..end].to_vec()).ok()
    }

    fn check(status: OSStatus, what: &str) -> Result<(), String> {
        if status == 0 {
            Ok(())
        } else {
            Err(format!("{what}: OSStatus {status}"))
        }
    }

    /// The kernel's signature of the server peer of `stream`, through its
    /// audit token (so a pid reused since the connect is refused).
    pub fn running_peer(stream: &UnixStream) -> Result<KernelSignature, String> {
        let mut token = [0u32; 8];
        let mut len = std::mem::size_of_val(&token) as libc::socklen_t;
        // SAFETY: token and len are valid for the sizes given.
        let got = unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                SOL_LOCAL,
                LOCAL_PEERTOKEN,
                token.as_mut_ptr().cast(),
                &mut len,
            )
        };
        if got != 0 {
            return Err(format!(
                "the peer's audit token is unknown ({})",
                std::io::Error::last_os_error()
            ));
        }
        let pid = token[5] as i32;
        let ops = |op: u32, buf: &mut [u8]| {
            // SAFETY: buf is valid for its length; token is a live audit token.
            unsafe { csops_audittoken(pid, op, buf.as_mut_ptr().cast(), buf.len(), &token) }
        };
        let mut status = [0u8; 4];
        if ops(CS_OPS_STATUS, &mut status) != 0 {
            return Err(format!(
                "the kernel has no code signing state for pid {pid} ({})",
                std::io::Error::last_os_error()
            ));
        }
        let mut cdhash = [0u8; 20];
        if ops(CS_OPS_CDHASH, &mut cdhash) != 0 {
            return Err(format!("pid {pid} has no cdhash"));
        }
        // The first call fails with ERANGE and says the length (big-endian, at 4).
        let mut header = [0u8; 8];
        ops(CS_OPS_BLOB, &mut header);
        let length = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;
        if !(12..=64 << 20).contains(&length) {
            return Err(format!("pid {pid}'s signature blob is not readable"));
        }
        let mut blob = vec![0u8; length + 8];
        if ops(CS_OPS_BLOB, &mut blob) != 0 {
            return Err(format!("pid {pid}'s signature blob is not readable"));
        }
        blob.truncate(length);
        Ok(KernelSignature {
            flags: u32::from_ne_bytes(status),
            cdhash,
            blob,
        })
    }

    /// `at` (seconds since the Unix epoch) as RFC 3339 UTC, for errors.
    fn utc(at: f64) -> String {
        chrono::DateTime::from_timestamp(at.floor() as i64, 0).map_or_else(
            || format!("{at} s after 1970"),
            |at| at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        )
    }

    /// The team ID (certificate OU) of the single CMS signer over
    /// `directory`, once its signature verifies and its chain to Apple Root
    /// CA is valid at its secure timestamp, or at `now` when it has none.
    pub(super) fn cms_signer_team(
        cms: &[u8],
        directory: &[u8],
        now: std::time::SystemTime,
    ) -> Result<String, String> {
        use sha2::Digest as _;
        let mut decoder: CFTypeRef = std::ptr::null();
        // SAFETY: decoder is a valid out-pointer.
        check(
            unsafe { CMSDecoderCreate(&mut decoder) },
            "CMSDecoderCreate",
        )?;
        let decoder = Cf::new(decoder, "CMSDecoderCreate")?;
        let content = data(directory)?;
        // SAFETY: decoder is live; cms is valid for its length.
        unsafe {
            check(
                CMSDecoderUpdateMessage(decoder.0, cms.as_ptr(), cms.len()),
                "its CMS signature does not decode",
            )?;
            check(
                CMSDecoderSetDetachedContent(decoder.0, content.0),
                "CMSDecoderSetDetachedContent",
            )?;
            check(
                CMSDecoderFinalizeMessage(decoder.0),
                "its CMS signature does not decode",
            )?;
        }
        let mut signers = 0usize;
        // SAFETY: decoder is live; signers is a valid out-pointer.
        check(
            unsafe { CMSDecoderGetNumSigners(decoder.0, &mut signers) },
            "CMSDecoderGetNumSigners",
        )?;
        if signers != 1 {
            return Err(format!("its CMS signature has {signers} signers, not 1"));
        }
        // SAFETY: no arguments.
        let policy = Cf::new(
            unsafe { SecPolicyCreateBasicX509() },
            "SecPolicyCreateBasicX509",
        )?;
        let (mut status, mut trust, mut verify) = (0u32, std::ptr::null(), 0);
        // The signature only; the chain is evaluated below at a time this
        // code chooses. CMSDecoder's own evaluation falls back from the
        // secure timestamp to the signingTime attribute, which the signer
        // picks: a holder of an expired or revoked leaf's key could backdate it.
        // This call also verifies the unsigned attributes (the RFC 3161
        // token's signature and imprint): a broken token fails it here.
        // SAFETY: decoder and policy are live; the out-pointers are valid.
        check(
            unsafe {
                CMSDecoderCopySignerStatus(
                    decoder.0,
                    0,
                    policy.0,
                    0,
                    &mut status,
                    &mut trust,
                    &mut verify,
                )
            },
            "CMSDecoderCopySignerStatus",
        )?;
        let trust = Cf::new(trust, "the signer's trust")?;
        if status != CMS_SIGNER_VALID || verify != 0 {
            return Err(format!(
                "its CMS signature does not verify (signer status {status}, result {verify})"
            ));
        }
        // The RFC 3161 timestamp token over this signer's signature (an
        // unsigned attribute, so the signer's signature does not cover it).
        // Its time is trusted only because the status check above verified
        // the token: Security caches the time while it decodes, before its
        // imprint check, and returns the cache here (the policy is then not
        // used). Keep this call after that check.
        // SAFETY: kSecPolicyAppleTimeStamping is Security's constant.
        let stamping = Cf::new(
            unsafe { SecPolicyCreateWithProperties(kSecPolicyAppleTimeStamping, std::ptr::null()) },
            "the time stamping policy",
        )?;
        let mut since_cf_epoch = 0f64;
        // SAFETY: decoder and stamping are live; since_cf_epoch is a valid out-pointer.
        let found = unsafe {
            CMSDecoderCopySignerTimestampWithPolicy(decoder.0, stamping.0, 0, &mut since_cf_epoch)
        } == 0;
        let (at, when) = match found.then_some(since_cf_epoch + CF_EPOCH) {
            Some(at) => (at, format!("its secure timestamp ({})", utc(at))),
            None => {
                let at = match now.duration_since(std::time::UNIX_EPOCH) {
                    Ok(since) => since.as_secs_f64(),
                    Err(before) => -before.duration().as_secs_f64(),
                };
                (at, format!("{} (it has no secure timestamp)", utc(at)))
            }
        };
        // SAFETY: no pointer arguments.
        let date = Cf::new(
            unsafe { CFDateCreate(std::ptr::null(), at - CF_EPOCH) },
            "CFDateCreate",
        )?;
        // SAFETY: trust and date are live.
        check(
            unsafe { SecTrustSetVerifyDate(trust.0, date.0) },
            "SecTrustSetVerifyDate",
        )?;
        let mut error: CFTypeRef = std::ptr::null();
        // SAFETY: trust is live; error is a valid out-pointer.
        if !unsafe { SecTrustEvaluateWithError(trust.0, &mut error) } {
            let code = Cf::new(error, "SecTrustEvaluateWithError")
                // SAFETY: the error is a live CFError.
                .map(|error| unsafe { CFErrorGetCode(error.0) })
                .unwrap_or(0);
            return Err(format!(
                "its signing certificate chain is not valid at {when} (OSStatus {code})"
            ));
        }
        // SAFETY: trust is live.
        let chain = Cf::new(
            unsafe { SecTrustCopyCertificateChain(trust.0) },
            "the chain",
        )?;
        // SAFETY: chain is a CFArray of SecCertificate.
        let count = unsafe { CFArrayGetCount(chain.0) };
        if count < 2 {
            return Err("its certificate chain is too short".into());
        }
        // SAFETY: indexes are in range; the array keeps its values alive.
        let (leaf, anchor) = unsafe {
            (
                CFArrayGetValueAtIndex(chain.0, 0),
                CFArrayGetValueAtIndex(chain.0, count - 1),
            )
        };
        // SAFETY: anchor is a SecCertificate.
        let anchor_der = Cf::new(unsafe { SecCertificateCopyData(anchor) }, "the anchor")?;
        let anchor_hash = sha2::Sha256::digest(bytes_of(anchor_der.0));
        let anchor_hex: String = anchor_hash.iter().map(|b| format!("{b:02x}")).collect();
        if anchor_hex != APPLE_ROOT_CA_SHA256 {
            return Err("its certificate chain does not end at Apple Root CA".into());
        }
        leaf_ou(leaf).ok_or_else(|| "its signing certificate has no OU".into())
    }

    /// The subject OU of certificate `cert`.
    fn leaf_ou(cert: CFTypeRef) -> Option<String> {
        // SAFETY: cert is a SecCertificate; a null keys array asks for every value.
        let values = Cf::new(
            unsafe { SecCertificateCopyValues(cert, std::ptr::null(), std::ptr::null_mut()) },
            "SecCertificateCopyValues",
        )
        .ok()?;
        // SAFETY: values is a CFDictionary; the constants are Security's keys.
        unsafe {
            let subject = CFDictionaryGetValue(values.0, kSecOIDX509V1SubjectName);
            if subject.is_null() || CFGetTypeID(subject) != CFDictionaryGetTypeID() {
                return None;
            }
            let fields = CFDictionaryGetValue(subject, kSecPropertyKeyValue);
            if fields.is_null() || CFGetTypeID(fields) != CFArrayGetTypeID() {
                return None;
            }
            for i in 0..CFArrayGetCount(fields) {
                let field = CFArrayGetValueAtIndex(fields, i);
                if CFGetTypeID(field) != CFDictionaryGetTypeID() {
                    continue;
                }
                let label = CFDictionaryGetValue(field, kSecPropertyKeyLabel);
                if !label.is_null() && CFEqual(label, kSecOIDOrganizationalUnitName) != 0 {
                    return string_of(CFDictionaryGetValue(field, kSecPropertyKeyValue));
                }
            }
        }
        None
    }

    /// The signer of the binary at `path`: its signature must be valid and
    /// anchored at Apple (`anchor apple generic`), with a team ID.
    pub fn of_file(path: &Path) -> Result<Signer, String> {
        use std::os::unix::ffi::OsStrExt as _;
        let raw = path.as_os_str().as_bytes();
        // SAFETY: raw is valid for its length.
        let url = Cf::new(
            unsafe {
                CFURLCreateFromFileSystemRepresentation(
                    std::ptr::null(),
                    raw.as_ptr(),
                    raw.len() as isize,
                    0,
                )
            },
            "CFURLCreateFromFileSystemRepresentation",
        )?;
        let mut code = std::ptr::null();
        // SAFETY: url is live; code is a valid out-pointer.
        check(
            unsafe { SecStaticCodeCreateWithPath(url.0, 0, &mut code) },
            &format!("{} has no code signature", path.display()),
        )?;
        let code = Cf::new(code, "SecStaticCodeCreateWithPath")?;
        let text = b"anchor apple generic";
        // SAFETY: text is valid for its length.
        let text = Cf::new(
            unsafe {
                CFStringCreateWithBytes(
                    std::ptr::null(),
                    text.as_ptr(),
                    text.len() as isize,
                    UTF8,
                    0,
                )
            },
            "CFStringCreateWithBytes",
        )?;
        let mut requirement = std::ptr::null();
        // SAFETY: text is live; requirement is a valid out-pointer.
        check(
            unsafe { SecRequirementCreateWithString(text.0, 0, &mut requirement) },
            "SecRequirementCreateWithString",
        )?;
        let requirement = Cf::new(requirement, "SecRequirementCreateWithString")?;
        // SAFETY: code and requirement are live.
        check(
            unsafe { SecStaticCodeCheckValidity(code.0, 0, requirement.0) },
            &format!(
                "{} is not validly signed by an Apple-issued certificate",
                path.display()
            ),
        )?;
        let mut info = std::ptr::null();
        // SAFETY: code is live; info is a valid out-pointer.
        check(
            unsafe { SecCodeCopySigningInformation(code.0, SIGNING_INFORMATION, &mut info) },
            "SecCodeCopySigningInformation",
        )?;
        let info = Cf::new(info, "SecCodeCopySigningInformation")?;
        // SAFETY: info is a CFDictionary; the keys are Security's constants.
        let (identifier, team) = unsafe {
            (
                string_of(CFDictionaryGetValue(info.0, kSecCodeInfoIdentifier)),
                string_of(CFDictionaryGetValue(info.0, kSecCodeInfoTeamIdentifier)),
            )
        };
        match (team, identifier) {
            (Some(team), Some(identifier)) => Ok(Signer { team, identifier }),
            _ => Err(format!("{} has no team ID or identifier", path.display())),
        }
    }
}
