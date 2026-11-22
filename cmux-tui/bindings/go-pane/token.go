package pane

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Claims are the capability token claims the spec defines. Ops and Scopes are
// alternatives: a token grants an op when the op's namespace is in NS and
// either the op name is in Ops or the op's IR scope is in Scopes.
type Claims struct {
	Sub    string   `json:"sub"`
	Page   string   `json:"page,omitempty"` // page id, on page tokens (aud "router")
	App    string   `json:"app"`
	NS     []string `json:"ns"`
	Scopes []string `json:"scopes,omitempty"`
	Ops    []string `json:"ops,omitempty"`
	// Roots are the absolute canonical directories that path params must
	// stay inside (decision 20). Empty means no path-taking op is allowed.
	Roots  []string `json:"roots,omitempty"`
	Origin string   `json:"origin,omitempty"`
	Aud    string   `json:"aud"`
	Exp    int64    `json:"exp"`
	Iat    int64    `json:"iat,omitempty"`
}

// Token verification errors. Verify wraps them, so use errors.Is.
var (
	ErrTokenMalformed = errors.New("pane: malformed capability token")
	ErrTokenHeader    = errors.New("pane: capability token header is not {alg: EdDSA, typ: cmux-cap+jwt}")
	ErrTokenSignature = errors.New("pane: capability token signature is invalid")
	ErrTokenExpired   = errors.New("pane: capability token expired")
	ErrTokenAudience  = errors.New("pane: capability token audience mismatch")
	ErrTokenOrigin    = errors.New("pane: capability token origin mismatch")
)

// tokenHeader is the JWS protected header. It must be exactly
// {"alg":"EdDSA","typ":"cmux-cap+jwt"} (decision 10, Rust lane R2).
type tokenHeader struct {
	Alg string `json:"alg"`
	Typ string `json:"typ"`
}

// TokenType is the JWS "typ" the router sets on capability tokens.
const TokenType = "cmux-cap+jwt"

var b64 = base64.RawURLEncoding

// MintToken signs claims as a compact JWS (alg EdDSA). The router mints
// tokens; the SDK exposes this for tests and fake routers.
func MintToken(key ed25519.PrivateKey, c Claims) (string, error) {
	h, err := json.Marshal(tokenHeader{Alg: "EdDSA", Typ: TokenType})
	if err != nil {
		return "", err
	}
	p, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	signing := b64.EncodeToString(h) + "." + b64.EncodeToString(p)
	sig := ed25519.Sign(key, []byte(signing))
	return signing + "." + b64.EncodeToString(sig), nil
}

// VerifyOptions are what a provider checks besides the signature.
type VerifyOptions struct {
	// Audience is the provider's app id; required.
	Audience string
	// Origin, when non-empty, must equal the token's origin claim. WebSocket
	// listeners pass the page's Origin header; unix peers have no origin and
	// pass "".
	Origin string
	// Now defaults to time.Now.
	Now func() time.Time
}

// VerifyToken checks a capability token offline: compact JWS shape, alg
// EdDSA, the router's signature, exp, aud and (optionally) origin. It returns
// the claims on success.
func VerifyToken(token string, routerKey ed25519.PublicKey, opts VerifyOptions) (*Claims, error) {
	if len(routerKey) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("%w: router key has %d bytes", ErrTokenSignature, len(routerKey))
	}
	if opts.Audience == "" {
		return nil, fmt.Errorf("%w: verifier has no audience", ErrTokenAudience)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("%w: want 3 segments, got %d", ErrTokenMalformed, len(parts))
	}
	hb, err := b64.DecodeString(parts[0])
	if err != nil {
		return nil, fmt.Errorf("%w: header: %v", ErrTokenMalformed, err)
	}
	var hm map[string]json.RawMessage
	if err := strictUnmarshal(hb, &hm); err != nil {
		return nil, fmt.Errorf("%w: header: %v", ErrTokenMalformed, err)
	}
	var h tokenHeader
	_ = json.Unmarshal(hb, &h)
	if len(hm) != 2 || h.Alg != "EdDSA" || h.Typ != TokenType {
		return nil, fmt.Errorf("%w: got %s", ErrTokenHeader, hb)
	}
	sig, err := b64.DecodeString(parts[2])
	if err != nil || len(sig) != ed25519.SignatureSize {
		return nil, fmt.Errorf("%w: bad signature encoding", ErrTokenMalformed)
	}
	if !ed25519.Verify(routerKey, []byte(parts[0]+"."+parts[1]), sig) {
		return nil, ErrTokenSignature
	}
	pb, err := b64.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("%w: claims: %v", ErrTokenMalformed, err)
	}
	var c Claims
	if err := strictUnmarshal(pb, &c); err != nil {
		return nil, fmt.Errorf("%w: claims: %v", ErrTokenMalformed, err)
	}
	if c.Sub == "" || c.App == "" || c.Aud == "" || c.Exp == 0 {
		return nil, fmt.Errorf("%w: sub, app, aud and exp are required", ErrTokenMalformed)
	}
	now := time.Now
	if opts.Now != nil {
		now = opts.Now
	}
	if now().Unix() >= c.Exp {
		return nil, ErrTokenExpired
	}
	if c.Aud != opts.Audience {
		return nil, fmt.Errorf("%w: token is for %q", ErrTokenAudience, c.Aud)
	}
	if opts.Origin != "" && c.Origin != opts.Origin {
		return nil, fmt.Errorf("%w: token is for %q", ErrTokenOrigin, c.Origin)
	}
	return &c, nil
}

// Grants reports whether the claims allow op, whose IR scope is scope.
func (c *Claims) Grants(op, scope string) bool {
	if c == nil {
		return false
	}
	nsOK := false
	for _, ns := range c.NS {
		if op == ns || strings.HasPrefix(op, ns+".") {
			nsOK = true
			break
		}
	}
	if !nsOK {
		return false
	}
	for _, o := range c.Ops {
		if o == op {
			return true
		}
	}
	for _, s := range c.Scopes {
		if s == scope {
			return true
		}
	}
	return false
}

// strictUnmarshal decodes exactly one JSON value; trailing data is rejected.
// Unknown claims are ignored, as JWT requires.
func strictUnmarshal(b []byte, v any) error {
	dec := json.NewDecoder(bytes.NewReader(b))
	if err := dec.Decode(v); err != nil {
		return err
	}
	if dec.More() {
		return errors.New("trailing data")
	}
	return nil
}

// ParseRouterKey decodes the router's public key as sent in the admission
// reply: unpadded base64url of the 32 raw Ed25519 bytes.
func ParseRouterKey(s string) (ed25519.PublicKey, error) {
	b, err := b64.DecodeString(s)
	if err != nil {
		return nil, fmt.Errorf("pane: router key: %w", err)
	}
	if len(b) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("pane: router key has %d bytes, want %d", len(b), ed25519.PublicKeySize)
	}
	return ed25519.PublicKey(b), nil
}

// EncodeRouterKey is the inverse of ParseRouterKey.
func EncodeRouterKey(k ed25519.PublicKey) string { return b64.EncodeToString(k) }
