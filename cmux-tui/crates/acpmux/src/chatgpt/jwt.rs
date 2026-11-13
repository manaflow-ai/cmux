//! ID token validation for Sign in with ChatGPT: the signature against the issuer's JWKS
//! (RS256 or ES256, through `ring`), then `iss`, `aud`, `exp` and `nonce`.

use base64::Engine as _;
use serde_json::Value;

/// Seconds of clock skew `exp` allows.
const LEEWAY: i64 = 60;

/// What a valid ID token says about the person.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Claims {
    pub sub: String,
    pub email: Option<String>,
    pub plan: Option<String>,
}

/// Why a token is refused; never the token itself.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Invalid {
    Malformed,
    /// No key of the JWKS has the token's `kid` (the caller may refetch the JWKS once).
    UnknownKey,
    Algorithm,
    Signature,
    Issuer,
    Audience,
    Expired,
    Nonce,
    NoSubject,
}

impl Invalid {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Malformed => "malformed",
            Self::UnknownKey => "unknown signing key",
            Self::Algorithm => "unsupported algorithm",
            Self::Signature => "bad signature",
            Self::Issuer => "wrong issuer",
            Self::Audience => "wrong audience",
            Self::Expired => "expired",
            Self::Nonce => "nonce mismatch",
            Self::NoSubject => "no subject",
        }
    }
}

fn b64(text: &str) -> Result<Vec<u8>, Invalid> {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(text.trim_end_matches('='))
        .map_err(|_| Invalid::Malformed)
}

fn json_part(text: &str) -> Result<Value, Invalid> {
    serde_json::from_slice(&b64(text)?).map_err(|_| Invalid::Malformed)
}

fn key_text<'a>(key: &'a Value, name: &str) -> Option<&'a str> {
    key.get(name).and_then(Value::as_str)
}

fn verify_signature(alg: &str, key: &Value, message: &[u8], sig: &[u8]) -> Result<(), Invalid> {
    use ring::signature;
    match alg {
        "RS256" => {
            if key_text(key, "kty") != Some("RSA") {
                return Err(Invalid::Algorithm);
            }
            let n = b64(key_text(key, "n").ok_or(Invalid::Malformed)?)?;
            let e = b64(key_text(key, "e").ok_or(Invalid::Malformed)?)?;
            signature::RsaPublicKeyComponents { n: &n, e: &e }
                .verify(&signature::RSA_PKCS1_2048_8192_SHA256, message, sig)
                .map_err(|_| Invalid::Signature)
        }
        "ES256" => {
            if key_text(key, "kty") != Some("EC") || key_text(key, "crv") != Some("P-256") {
                return Err(Invalid::Algorithm);
            }
            let x = b64(key_text(key, "x").ok_or(Invalid::Malformed)?)?;
            let y = b64(key_text(key, "y").ok_or(Invalid::Malformed)?)?;
            if x.len() != 32 || y.len() != 32 {
                return Err(Invalid::Malformed);
            }
            let mut point = Vec::with_capacity(65);
            point.push(4);
            point.extend_from_slice(&x);
            point.extend_from_slice(&y);
            signature::UnparsedPublicKey::new(&signature::ECDSA_P256_SHA256_FIXED, point)
                .verify(message, sig)
                .map_err(|_| Invalid::Signature)
        }
        _ => Err(Invalid::Algorithm),
    }
}

/// Validates `token` against `keys` (a JWKS `keys` array) and the expected issuer, audience
/// (the issued client id) and nonce, at unix time `now`.
pub(crate) fn verify(
    token: &str,
    keys: &[Value],
    issuer: &str,
    audience: &str,
    nonce: &str,
    now: i64,
) -> Result<Claims, Invalid> {
    let mut parts = token.split('.');
    let (Some(head), Some(body), Some(sig), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(Invalid::Malformed);
    };
    let header = json_part(head)?;
    let alg = header.get("alg").and_then(Value::as_str).ok_or(Invalid::Malformed)?;
    let kid = header.get("kid").and_then(Value::as_str);
    let key = match kid {
        Some(kid) => keys.iter().find(|k| key_text(k, "kid") == Some(kid)),
        None if keys.len() == 1 => keys.first(),
        None => None,
    }
    .ok_or(Invalid::UnknownKey)?;
    if let Some(key_alg) = key_text(key, "alg")
        && key_alg != alg
    {
        return Err(Invalid::Algorithm);
    }
    let message = &token.as_bytes()[..head.len() + 1 + body.len()];
    verify_signature(alg, key, message, &b64(sig)?)?;
    let claims = json_part(body)?;
    if claims.get("iss").and_then(Value::as_str) != Some(issuer) {
        return Err(Invalid::Issuer);
    }
    let aud_ok = match claims.get("aud") {
        Some(Value::String(a)) => a == audience,
        Some(Value::Array(list)) => list.iter().any(|a| a.as_str() == Some(audience)),
        _ => false,
    };
    if !aud_ok {
        return Err(Invalid::Audience);
    }
    match claims.get("exp").and_then(Value::as_i64) {
        Some(exp) if exp + LEEWAY > now => {}
        _ => return Err(Invalid::Expired),
    }
    if claims.get("nonce").and_then(Value::as_str) != Some(nonce) {
        return Err(Invalid::Nonce);
    }
    let text = |pointer: &str| {
        claims.pointer(pointer).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned)
    };
    let sub = text("/sub").ok_or(Invalid::NoSubject)?;
    Ok(Claims {
        sub,
        email: text("/email"),
        plan: text("/https:~1~1api.openai.com~1auth/chatgpt_plan_type"),
    })
}
