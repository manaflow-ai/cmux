package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	pane "github.com/manaflow-ai/cmux/cmux-tui/bindings/go-pane"
	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go-pane/examples/hello/hellopane"
)

// Shared wire conformance vectors (spec "First slice" item 5), written by the
// Rust lane and committed at cmux-tui/crates/cmux-pane-protocol/spec/
// (PANE_PROTOCOL_VECTORS overrides the path). Every section that concerns
// a Go peer is checked, and an unknown vector shape fails instead of being
// skipped. fragments and ir_keywords concern the generator and are checked by
// codegen/tests/test_pane_emit_go.py.

type vectorFile struct {
	Version            string            `json:"version"`
	Vectors            []vector          `json:"vectors"`
	UnixFraming        []framingVector   `json:"unix_framing"`
	TransportEnvelopes []vector          `json:"transport_envelopes"`
	Token              tokenSection      `json:"token"`
	Session            []sessionVector   `json:"session"`
	Fragments          []json.RawMessage `json:"fragments"`
	Roots              rootsSection      `json:"roots"`
	Admission          admissionSection  `json:"admission"`
	IRKeywords         json.RawMessage   `json:"ir_keywords"`
}

type vector struct {
	Name       string          `json:"name"`
	Kind       string          `json:"kind"`
	Valid      *bool           `json:"valid"`
	Text       *string         `json:"text"`
	Encoded    *string         `json:"encoded"`
	Hex        *string         `json:"hex"`
	Stream     *uint32         `json:"stream"`
	Credit     *uint32         `json:"credit"`
	PayloadHex *string         `json:"payload_hex"`
	Type       *string         `json:"type"`
	Value      json.RawMessage `json:"value"`
}

type framingVector struct {
	Name       string  `json:"name"`
	Kind       string  `json:"kind"`
	Valid      bool    `json:"valid"`
	Hex        string  `json:"hex"`
	Text       *string `json:"text"`
	HeaderOnly bool    `json:"header_only"`
	DataFrame  *struct {
		Stream     uint32 `json:"stream"`
		Credit     uint32 `json:"credit"`
		PayloadHex string `json:"payload_hex"`
	} `json:"data_frame"`
}

type tokenSection struct {
	Claims       pane.Claims `json:"claims"`
	Header       map[string]string
	PublicKeyHex string `json:"public_key_hex"`
	SeedHex      string `json:"seed_hex"`
	Token        string `json:"token"`
	Checks       []struct {
		Name   string  `json:"name"`
		Token  string  `json:"token"`
		Aud    string  `json:"aud"`
		Origin *string `json:"origin"`
		Now    int64   `json:"now"`
		Result string  `json:"result"`
	} `json:"checks"`
	Allows []struct {
		Op      string `json:"op"`
		Scope   string `json:"scope"`
		Allowed bool   `json:"allowed"`
	} `json:"allows"`
}

type rootsSection struct {
	Layout struct {
		Dirs     []string `json:"dirs"`
		Symlinks []struct {
			Path   string `json:"path"`
			Target string `json:"target"`
		} `json:"symlinks"`
	} `json:"layout"`
	Cases []struct {
		Name    string   `json:"name"`
		Path    string   `json:"path"`
		Roots   []string `json:"roots"`
		Allowed bool     `json:"allowed"`
	} `json:"cases"`
	RefusalCode string `json:"refusal_code"`
}

type admissionSection struct {
	RouterIRSHA256 string `json:"router_ir_sha256"`
	Cases          []struct {
		Name     string `json:"name"`
		App      string `json:"app"`
		IRSHA256 string `json:"ir_sha256"`
		Result   string `json:"result"`
	} `json:"cases"`
}

type sessionVector struct {
	Name   string                       `json:"name"`
	Send   []string                     `json:"send"`
	Expect []map[string]json.RawMessage `json:"expect"`
}

var whitespace = regexp.MustCompile(`\s+`)

func loadVectors(t *testing.T) *vectorFile {
	t.Helper()
	// Default: the vectors committed next to the Rust IR.
	path := os.Getenv("PANE_PROTOCOL_VECTORS")
	if path == "" {
		path = "../../../../crates/cmux-pane-protocol/spec/pane-protocol-vectors.json"
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var f vectorFile
	if err := json.Unmarshal(raw, &f); err != nil {
		// The TS harness also accepts a bare array of vectors.
		var list []vector
		if err2 := json.Unmarshal(raw, &list); err2 != nil {
			t.Fatalf("vectors file must be {vectors: [...], ...} or an array: %v", err)
		}
		f.Vectors = list
	}
	return &f
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(whitespace.ReplaceAllString(s, ""))
	if err != nil {
		t.Fatalf("bad hex %q: %v", s, err)
	}
	return b
}

func TestConformanceVectors(t *testing.T) {
	f := loadVectors(t)
	for i, v := range f.Vectors {
		name := v.Name
		if name == "" {
			name = fmt.Sprintf("#%d", i)
		}
		valid := v.Valid == nil || *v.Valid
		switch {
		case v.Text != nil:
			m, err := pane.DecodeMessage([]byte(*v.Text))
			if (err == nil) != valid {
				t.Errorf("%s: envelope valid=%v, got err %v", name, valid, err)
				continue
			}
			if err == nil && v.Encoded != nil {
				got, err := m.Encode()
				if err != nil || string(got) != *v.Encoded {
					t.Errorf("%s: encoded\n got %s (%v)\nwant %s", name, got, err, *v.Encoded)
				}
			}
		case v.Hex != nil:
			fr, err := pane.DecodeBinaryFrame(mustHex(t, *v.Hex))
			if (err == nil) != valid {
				t.Errorf("%s: data frame valid=%v, got err %v", name, valid, err)
				continue
			}
			if !valid {
				continue
			}
			if v.Stream != nil && fr.Stream != *v.Stream {
				t.Errorf("%s: stream %d", name, fr.Stream)
			}
			if v.Credit != nil && fr.Credit != *v.Credit {
				t.Errorf("%s: credit %d", name, fr.Credit)
			}
			if v.PayloadHex != nil && hex.EncodeToString(fr.Payload) != *v.PayloadHex {
				t.Errorf("%s: payload", name)
			}
			if back, _ := pane.EncodeBinaryFrame(fr); !bytes.Equal(back, mustHex(t, *v.Hex)) {
				t.Errorf("%s: re-encoded frame differs", name)
			}
		case v.Type != nil:
			validate, ok := hellopane.Validators[*v.Type]
			if !ok {
				t.Errorf("%s: no generated validator for %s", name, *v.Type)
				continue
			}
			dv, err := pane.DecodeValue(v.Value)
			if err == nil {
				err = validate(dv)
			}
			if (err == nil) != valid {
				t.Errorf("%s: %s valid=%v, got err %v", name, *v.Type, valid, err)
			}
		default:
			t.Errorf("%s: unrecognized vector shape", name)
		}
	}
	if len(f.Vectors) == 0 {
		t.Error("vectors[] is empty")
	}
}

func TestConformanceUnixFraming(t *testing.T) {
	f := loadVectors(t)
	for _, v := range f.UnixFraming {
		b := mustHex(t, v.Hex)
		if v.HeaderOnly {
			var h [4]byte
			copy(h[:], b)
			_, _, err := pane.ParseFrameHeader(h)
			if (err == nil) != v.Valid {
				t.Errorf("%s: header valid=%v, got %v", v.Name, v.Valid, err)
			}
			continue
		}
		r := bytes.NewReader(b)
		fr, err := pane.ReadAnyFrame(r)
		if (err == nil) != v.Valid {
			t.Errorf("%s: valid=%v, got %v", v.Name, v.Valid, err)
			continue
		}
		if !v.Valid {
			continue
		}
		if r.Len() != 0 {
			t.Errorf("%s: %d trailing bytes", v.Name, r.Len())
		}
		switch v.Kind {
		case "text":
			if fr.Binary || v.Text == nil || string(fr.Payload) != *v.Text {
				t.Errorf("%s: got %+v", v.Name, fr)
			}
			var out bytes.Buffer
			_ = pane.WriteFrame(&out, fr.Payload)
			if !bytes.Equal(out.Bytes(), b) {
				t.Errorf("%s: re-encoded text frame differs", v.Name)
			}
		case "binary":
			if !fr.Binary || v.DataFrame == nil {
				t.Errorf("%s: got %+v", v.Name, fr)
				continue
			}
			df, err := pane.DecodeBinaryFrame(fr.Payload)
			if err != nil || df.Stream != v.DataFrame.Stream || df.Credit != v.DataFrame.Credit ||
				hex.EncodeToString(df.Payload) != v.DataFrame.PayloadHex {
				t.Errorf("%s: data frame %+v %v", v.Name, df, err)
			}
			var out bytes.Buffer
			_ = pane.WriteBinaryFrame(&out, fr.Payload)
			if !bytes.Equal(out.Bytes(), b) {
				t.Errorf("%s: re-encoded binary frame differs", v.Name)
			}
		default:
			t.Errorf("%s: unknown kind %q", v.Name, v.Kind)
		}
	}
	for _, v := range f.TransportEnvelopes {
		_, err := pane.DecodeMessage([]byte(*v.Text))
		if (err == nil) != (v.Valid == nil || *v.Valid) {
			t.Errorf("transport %s: got %v", v.Name, err)
		}
	}
}

func vectorKeys(t *testing.T, tok tokenSection) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	priv := ed25519.NewKeyFromSeed(mustHex(t, tok.SeedHex))
	pub := priv.Public().(ed25519.PublicKey)
	if hex.EncodeToString(pub) != tok.PublicKeyHex {
		t.Fatalf("public key from seed is %x, vectors say %s", pub, tok.PublicKeyHex)
	}
	return pub, priv
}

func tokenResult(err error) string {
	switch {
	case err == nil:
		return "ok"
	case errors.Is(err, pane.ErrTokenExpired):
		return "expired"
	case errors.Is(err, pane.ErrTokenAudience):
		return "wrong_audience"
	case errors.Is(err, pane.ErrTokenOrigin):
		return "wrong_origin"
	case errors.Is(err, pane.ErrTokenSignature):
		return "bad_signature"
	case errors.Is(err, pane.ErrTokenHeader):
		return "wrong_header"
	case errors.Is(err, pane.ErrTokenMalformed):
		return "malformed"
	}
	return "unknown: " + err.Error()
}

func TestConformanceToken(t *testing.T) {
	f := loadVectors(t)
	tok := f.Token
	pub, priv := vectorKeys(t, tok)
	// Minting the vector claims with the vector key reproduces the token byte
	// for byte (Ed25519 is deterministic and the claim order is canonical).
	minted, err := pane.MintToken(priv, tok.Claims)
	if err != nil || minted != tok.Token {
		t.Errorf("mint:\n got %s\nwant %s", minted, tok.Token)
	}
	if !reflect.DeepEqual(tok.Header, map[string]string{"alg": "EdDSA", "typ": pane.TokenType}) {
		t.Errorf("header %v", tok.Header)
	}
	for _, c := range tok.Checks {
		origin := ""
		if c.Origin != nil {
			origin = *c.Origin
		}
		now := time.Unix(c.Now, 0)
		_, err := pane.VerifyToken(c.Token, pub, pane.VerifyOptions{Audience: c.Aud, Origin: origin, Now: func() time.Time { return now }})
		if got := tokenResult(err); got != c.Result {
			t.Errorf("%s: got %s (%v), want %s", c.Name, got, err, c.Result)
		}
	}
	for _, a := range tok.Allows {
		if got := tok.Claims.Grants(a.Op, a.Scope); got != a.Allowed {
			t.Errorf("allows %s %s: got %v", a.Op, a.Scope, got)
		}
	}
}

// TestConformanceSession plays each session vector against the example
// provider's direct data-plane listener, signed by the vector router key.
func TestConformanceSession(t *testing.T) {
	f := loadVectors(t)
	pub, _ := vectorKeys(t, f.Token)
	p, err := newProvider()
	if err != nil {
		t.Fatal(err)
	}
	p.SetRouterKey(pub)
	dir := shortTempDir(t)
	ln, err := pane.ListenUnix(filepath.Join(dir, "hello.sock"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go p.ServeDirect(ctx, ln, pane.DirectOptions{Logf: quiet})

	for _, sv := range f.Session {
		t.Run(sv.Name, func(t *testing.T) {
			nc, err := net.Dial("unix", ln.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			defer nc.Close()
			for _, m := range sv.Send {
				if err := pane.WriteFrame(nc, []byte(m)); err != nil {
					t.Fatal(err)
				}
			}
			for i, want := range sv.Expect {
				_ = nc.SetReadDeadline(time.Now().Add(5 * time.Second))
				b, err := pane.ReadFrame(nc)
				if err != nil {
					t.Fatalf("expect[%d] %v: %v", i, want, err)
				}
				var got map[string]json.RawMessage
				if err := json.Unmarshal(b, &got); err != nil {
					t.Fatal(err)
				}
				for k, w := range want {
					var gv, wv any
					_ = json.Unmarshal(got[k], &gv)
					_ = json.Unmarshal(w, &wv)
					if !reflect.DeepEqual(gv, wv) {
						t.Errorf("expect[%d].%s: got %s, want %s (message %s)", i, k, got[k], w, b)
					}
				}
			}
		})
	}
	if len(f.Session) == 0 {
		t.Error("session vectors are empty")
	}
}

// TestConformanceRoots builds the vector layout under a temp dir ($BASE) and
// checks path confinement (decision 20), both through ConfinePath and
// through a real call to a path-taking op.
func TestConformanceRoots(t *testing.T) {
	f := loadVectors(t)
	r := f.Roots
	if len(r.Cases) == 0 {
		t.Fatal("roots vectors are empty")
	}
	base := t.TempDir()
	for _, d := range r.Layout.Dirs {
		if err := os.MkdirAll(filepath.Join(base, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, l := range r.Layout.Symlinks {
		if err := os.Symlink(l.Target, filepath.Join(base, l.Path)); err != nil {
			t.Fatal(err)
		}
	}
	expand := func(s string) string { return strings.ReplaceAll(s, "$BASE", base) }

	// cmux.git.status from the real IR: its `paths` is ["cwd"].
	p, err := pane.NewProvider("cmux", hellopane.Catalog, "cmux")
	if err != nil {
		t.Fatal(err)
	}
	got := make(chan string, 1)
	_ = p.Register(hellopane.OpCmuxGitStatus, func(ctx context.Context, call *pane.Call, raw json.RawMessage) (json.RawMessage, error) {
		var v hellopane.GitStatusParams
		_ = json.Unmarshal(raw, &v)
		got <- v.Cwd
		return json.Marshal(hellopane.GitStatus{})
	})
	pub, priv, _ := ed25519.GenerateKey(nil)
	p.SetRouterKey(pub)
	ln, err := pane.ListenUnix(filepath.Join(shortTempDir(t), "p.sock"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go p.ServeDirect(ctx, ln, pane.DirectOptions{Logf: quiet})

	for _, c := range r.Cases {
		roots := make([]string, len(c.Roots))
		for i, root := range c.Roots {
			roots[i] = expand(root)
		}
		path := expand(c.Path)
		canonical, err := pane.ConfinePath(path, roots)
		if (err == nil) != c.Allowed {
			t.Errorf("%s: ConfinePath allowed=%v, got %q %v", c.Name, c.Allowed, canonical, err)
		}

		tok, _ := pane.MintToken(priv, pane.Claims{Sub: "s", App: "a.b", NS: []string{"cmux"}, Scopes: []string{"git:read"},
			Roots: roots, Aud: "cmux", Exp: time.Now().Add(time.Minute).Unix()})
		nc, err := net.Dial("unix", ln.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		auth, _ := pane.NewAuth(tok).Encode()
		_ = pane.WriteFrame(nc, auth)
		conn := pane.NewConn(nc, pane.ConnOptions{Logf: quiet})
		go conn.Serve()
		_, callErr := conn.Call(context.Background(), hellopane.OpCmuxGitStatus, map[string]string{"cwd": path})
		conn.Close()
		if c.Allowed {
			if callErr != nil {
				t.Errorf("%s: call refused: %v", c.Name, callErr)
				continue
			}
			if h := <-got; h != canonical {
				t.Errorf("%s: handler got %q, want the canonical %q", c.Name, h, canonical)
			}
		} else {
			var e *pane.Error
			if !errors.As(callErr, &e) || e.Code != r.RefusalCode {
				t.Errorf("%s: got %v, want %s", c.Name, callErr, r.RefusalCode)
			}
		}
	}
}

func TestConformanceAdmission(t *testing.T) {
	f := loadVectors(t)
	a := f.Admission
	if len(a.Cases) == 0 {
		t.Fatal("admission vectors are empty")
	}
	if a.RouterIRSHA256 != hellopane.IRSHA256 {
		t.Errorf("router IR digest %s, generated package has %s (regenerate from the same IR)", a.RouterIRSHA256, hellopane.IRSHA256)
	}
	for _, c := range a.Cases {
		sha := c.IRSHA256
		if sha == "router" {
			sha = a.RouterIRSHA256
		}
		h := pane.HelloParams{App: c.App, IR: pane.HelloIR{SHA256: sha}}
		result := "ok"
		if e := pane.CheckHello(&h, a.RouterIRSHA256); e != nil {
			var d struct{ Reason string }
			_ = json.Unmarshal(e.Details, &d)
			result = e.Code + ":" + d.Reason
		}
		if result != c.Result {
			t.Errorf("%s: got %s, want %s", c.Name, result, c.Result)
		}
	}
}
