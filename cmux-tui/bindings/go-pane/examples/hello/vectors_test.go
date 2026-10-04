package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"testing"

	pane "github.com/manaflow-ai/cmux/cmux-tui/bindings/go-pane"
	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go-pane/examples/hello/hellopane"
)

// Shared wire conformance vectors (spec "First slice" item 5). The Rust lane
// writes them; until they are committed this reads PANE_PROTOCOL_VECTORS or
// the coordination path and skips when neither exists. It accepts the same
// shapes as the TS harness and fails on any vector it does not understand:
//
//	{ "name", "text": "<envelope json>", "valid": bool }
//	{ "name", "hex": "<binary frame hex>", "valid": bool, "stream"?, "credit"?, "payload_hex"? }
//	{ "name", "type": "<IR type>", "value": <json>, "valid": bool }
type vector struct {
	Name       string          `json:"name"`
	Valid      *bool           `json:"valid"`
	Text       *string         `json:"text"`
	Hex        *string         `json:"hex"`
	Stream     *uint32         `json:"stream"`
	Credit     *uint32         `json:"credit"`
	PayloadHex *string         `json:"payload_hex"`
	Type       *string         `json:"type"`
	Value      json.RawMessage `json:"value"`
}

var whitespace = regexp.MustCompile(`\s+`)

func TestConformanceVectors(t *testing.T) {
	path := os.Getenv("PANE_PROTOCOL_VECTORS")
	if path == "" {
		path = "/tmp/pane-protocol/vectors.json"
	}
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		t.Skipf("no vectors at %s", path)
	}
	if err != nil {
		t.Fatal(err)
	}
	var list []vector
	if err := json.Unmarshal(raw, &list); err != nil {
		var wrapped struct{ Vectors []vector }
		if err2 := json.Unmarshal(raw, &wrapped); err2 != nil || wrapped.Vectors == nil {
			t.Fatalf("vectors file must be an array or {vectors: [...]}: %v", err)
		}
		list = wrapped.Vectors
	}
	for i, v := range list {
		name := v.Name
		if name == "" {
			name = fmt.Sprintf("#%d", i)
		}
		valid := v.Valid == nil || *v.Valid
		switch {
		case v.Text != nil:
			_, err := pane.DecodeMessage([]byte(*v.Text))
			if (err == nil) != valid {
				t.Errorf("%s: envelope valid=%v, got err %v", name, valid, err)
			}
		case v.Hex != nil:
			b, err := hex.DecodeString(whitespace.ReplaceAllString(*v.Hex, ""))
			if err != nil {
				t.Errorf("%s: bad hex: %v", name, err)
				continue
			}
			f, err := pane.DecodeBinaryFrame(b)
			if (err == nil) != valid {
				t.Errorf("%s: binary frame valid=%v, got err %v", name, valid, err)
				continue
			}
			if !valid {
				continue
			}
			if v.Stream != nil && f.Stream != *v.Stream {
				t.Errorf("%s: stream %d", name, f.Stream)
			}
			if v.Credit != nil && f.Credit != *v.Credit {
				t.Errorf("%s: credit %d", name, f.Credit)
			}
			if v.PayloadHex != nil && hex.EncodeToString(f.Payload) != *v.PayloadHex {
				t.Errorf("%s: payload", name)
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
}
