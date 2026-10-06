package pane

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"
)

func testKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

func helloClaims(exp time.Time) Claims {
	return Claims{
		Sub: "surface:42", App: "com.acme.page", NS: []string{"com.example.hello"},
		Scopes: []string{"hello:read"}, Origin: "http://127.0.0.1:4100",
		Exp: exp.Unix(), Aud: "com.example.hello",
	}
}

func TestTokenVerifyGood(t *testing.T) {
	pub, priv := testKey(t)
	tok, err := MintToken(priv, helloClaims(time.Now().Add(5*time.Minute)))
	if err != nil {
		t.Fatal(err)
	}
	c, err := VerifyToken(tok, pub, VerifyOptions{Audience: "com.example.hello", Origin: "http://127.0.0.1:4100"})
	if err != nil {
		t.Fatal(err)
	}
	if c.Sub != "surface:42" || c.App != "com.acme.page" || !c.Grants("com.example.hello.greet.say", "hello:read") {
		t.Fatalf("claims %+v", c)
	}
	// Unix peers have no origin; the origin claim is not checked for them.
	if _, err := VerifyToken(tok, pub, VerifyOptions{Audience: "com.example.hello"}); err != nil {
		t.Fatal(err)
	}
}

func TestTokenVerifyExpired(t *testing.T) {
	pub, priv := testKey(t)
	now := time.Unix(1_800_000_000, 0)
	tok, _ := MintToken(priv, helloClaims(now))
	_, err := VerifyToken(tok, pub, VerifyOptions{Audience: "com.example.hello", Now: func() time.Time { return now }})
	if !errors.Is(err, ErrTokenExpired) {
		t.Fatalf("exp == now must be expired, got %v", err)
	}
	_, err = VerifyToken(tok, pub, VerifyOptions{Audience: "com.example.hello", Now: func() time.Time { return now.Add(-time.Second) }})
	if err != nil {
		t.Fatalf("one second before exp: %v", err)
	}
}

func TestTokenVerifyWrongAudience(t *testing.T) {
	pub, priv := testKey(t)
	tok, _ := MintToken(priv, helloClaims(time.Now().Add(time.Minute)))
	_, err := VerifyToken(tok, pub, VerifyOptions{Audience: "com.acme.diff"})
	if !errors.Is(err, ErrTokenAudience) {
		t.Fatalf("got %v", err)
	}
	if _, err := VerifyToken(tok, pub, VerifyOptions{}); !errors.Is(err, ErrTokenAudience) {
		t.Fatalf("empty verifier audience: %v", err)
	}
}

func TestTokenVerifyRejectsTampering(t *testing.T) {
	pub, priv := testKey(t)
	otherPub, otherPriv := testKey(t)
	_ = otherPub
	exp := time.Now().Add(time.Minute)
	good, _ := MintToken(priv, helloClaims(exp))
	forged, _ := MintToken(otherPriv, helloClaims(exp))
	parts := strings.Split(good, ".")

	lifted := helloClaims(exp)
	lifted.Scopes = append(lifted.Scopes, "git:write")
	liftedTok, _ := MintToken(otherPriv, lifted)
	swapped := parts[0] + "." + strings.Split(liftedTok, ".")[1] + "." + parts[2]

	none := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none","typ":"cmux-cap+jwt"}`)) + "." + parts[1] + "." + parts[2]
	crit := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"EdDSA","typ":"cmux-cap+jwt","crit":["x"]}`)) + "." + parts[1] + "." + parts[2]
	noTyp := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"EdDSA"}`)) + "." + parts[1] + "." + parts[2]

	cases := map[string]struct {
		tok  string
		want error
	}{
		"other key":      {forged, ErrTokenSignature},
		"swapped claims": {swapped, ErrTokenSignature},
		"alg none":       {none, ErrTokenHeader},
		"crit header":    {crit, ErrTokenHeader},
		"no typ":         {noTyp, ErrTokenHeader},
		"two segments":   {parts[0] + "." + parts[1], ErrTokenMalformed},
		"bad base64 sig": {parts[0] + "." + parts[1] + ".!!", ErrTokenMalformed},
		"empty":          {"", ErrTokenMalformed},
	}
	for name, c := range cases {
		if _, err := VerifyToken(c.tok, pub, VerifyOptions{Audience: "com.example.hello"}); !errors.Is(err, c.want) {
			t.Errorf("%s: got %v want %v", name, err, c.want)
		}
	}
	if _, err := VerifyToken(good, pub, VerifyOptions{Audience: "com.example.hello", Origin: "https://evil.example"}); !errors.Is(err, ErrTokenOrigin) {
		t.Errorf("origin: got %v", err)
	}
}

func TestClaimsGrants(t *testing.T) {
	c := &Claims{NS: []string{"com.example.hello"}, Scopes: []string{"hello:read"}, Ops: []string{"com.example.hello.admin.reset"}}
	cases := []struct {
		op, scope string
		want      bool
	}{
		{"com.example.hello.greet.say", "hello:read", true},
		{"com.example.hello.admin.reset", "com.example.hello:admin", true}, // granted by op name
		{"com.example.hello.admin.wipe", "com.example.hello:admin", false},
		{"com.example.hellox.greet.say", "hello:read", false}, // prefix is not a namespace
		{"cmux.git.status", "hello:read", false},              // scope without namespace
	}
	for _, tc := range cases {
		if got := c.Grants(tc.op, tc.scope); got != tc.want {
			t.Errorf("Grants(%s, %s) = %v", tc.op, tc.scope, got)
		}
	}
	var nilClaims *Claims
	if nilClaims.Grants("a.b.c", "x") {
		t.Fatal("nil claims grant nothing")
	}
}

func TestRouterKeyEncoding(t *testing.T) {
	pub, _ := testKey(t)
	back, err := ParseRouterKey(EncodeRouterKey(pub))
	if err != nil || !back.Equal(pub) {
		t.Fatalf("round trip: %v", err)
	}
	if _, err := ParseRouterKey("AAAA"); err == nil {
		t.Fatal("short key accepted")
	}
}
