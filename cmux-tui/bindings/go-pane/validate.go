package pane

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// ValidationError reports where a value violates its IR schema. Path is a
// JSON Pointer ("" for the root, "/files/2/path"), as in the TS lane.
type ValidationError struct {
	Path   string
	Reason string
}

func (e *ValidationError) Error() string {
	if e.Path == "" {
		return "/: " + e.Reason
	}
	return e.Path + ": " + e.Reason
}

// Invalid builds a *ValidationError.
func Invalid(path, format string, args ...any) error {
	return &ValidationError{Path: path, Reason: fmt.Sprintf(format, args...)}
}

// DecodeValue parses exactly one JSON value, keeping numbers as json.Number
// so integer checks are exact.
func DecodeValue(raw []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, &ValidationError{Path: "", Reason: "invalid JSON: " + err.Error()}
	}
	if dec.More() {
		return nil, &ValidationError{Path: "", Reason: "trailing data after JSON value"}
	}
	return v, nil
}

// DecodeAndValidate validates raw with validate and then unmarshals it into
// T. A failure is returned as *Error with code (CodeInvalidParams,
// CodeInvalidResult or CodeInvalidEvent) and details
// {"issues":[{"path":...,"message":...}]}, the TS lane's shape.
func DecodeAndValidate[T any](raw []byte, validate func(any) error, code string) (T, error) {
	var out T
	v, err := DecodeValue(raw)
	if err == nil {
		err = validate(v)
	}
	if err == nil {
		if uerr := json.Unmarshal(raw, &out); uerr != nil {
			err = &ValidationError{Path: "", Reason: uerr.Error()}
		}
	}
	if err != nil {
		return out, validationWireError(code, err)
	}
	return out, nil
}

// EncodeAndValidate marshals v and validates the JSON it produced, so a
// sender never puts a value on the wire that the receiver would reject.
func EncodeAndValidate(v any, validate func(any) error, code string) (json.RawMessage, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, validationWireError(code, err)
	}
	dv, err := DecodeValue(raw)
	if err == nil {
		err = validate(dv)
	}
	if err != nil {
		return nil, validationWireError(code, err)
	}
	return raw, nil
}

func validationWireError(code string, err error) *Error {
	e := &Error{Code: code, Message: err.Error()}
	var ve *ValidationError
	if errors.As(err, &ve) {
		type issue struct {
			Path    string `json:"path"`
			Message string `json:"message"`
		}
		e.Details, _ = json.Marshal(map[string][]issue{"issues": {{Path: ve.Path, Message: ve.Reason}}})
	}
	return e
}

// Helpers used by generated validators.

// AsObject checks that v is a JSON object.
func AsObject(v any, path string) (map[string]any, error) {
	o, ok := v.(map[string]any)
	if !ok {
		return nil, Invalid(path, "expected object, got %s", jsonKind(v))
	}
	return o, nil
}

// AsArray checks that v is a JSON array.
func AsArray(v any, path string) ([]any, error) {
	a, ok := v.([]any)
	if !ok {
		return nil, Invalid(path, "expected array, got %s", jsonKind(v))
	}
	return a, nil
}

// CheckString checks that v is a string; when enum is non-empty, one of it.
func CheckString(v any, path string, enum ...string) error {
	s, ok := v.(string)
	if !ok {
		return Invalid(path, "expected string, got %s", jsonKind(v))
	}
	if len(enum) == 0 {
		return nil
	}
	for _, e := range enum {
		if s == e {
			return nil
		}
	}
	return Invalid(path, "%q is not one of %q", s, enum)
}

// CheckBool checks that v is a boolean.
func CheckBool(v any, path string) error {
	if _, ok := v.(bool); !ok {
		return Invalid(path, "expected boolean, got %s", jsonKind(v))
	}
	return nil
}

// CheckNumber checks that v is a number.
func CheckNumber(v any, path string) error {
	n, ok := v.(json.Number)
	if !ok {
		return Invalid(path, "expected number, got %s", jsonKind(v))
	}
	if _, err := n.Float64(); err != nil {
		return Invalid(path, "number out of range")
	}
	return nil
}

// CheckInt checks that v is an integer that fits int64 and lies in
// [min, max] when those bounds are given.
func CheckInt(v any, path string, min, max *int64) error {
	n, ok := v.(json.Number)
	if !ok {
		return Invalid(path, "expected integer, got %s", jsonKind(v))
	}
	i, err := strconv.ParseInt(n.String(), 10, 64)
	if err != nil {
		return Invalid(path, "expected 64-bit signed integer, got %s", n)
	}
	if min != nil && i < *min {
		return Invalid(path, "%d is below minimum %d", i, *min)
	}
	if max != nil && i > *max {
		return Invalid(path, "%d is above maximum %d", i, *max)
	}
	return nil
}

// CheckUint checks that v is a non-negative integer that fits uint64 and is
// at most max when given.
func CheckUint(v any, path string, max *uint64) error {
	n, ok := v.(json.Number)
	if !ok {
		return Invalid(path, "expected integer, got %s", jsonKind(v))
	}
	u, err := strconv.ParseUint(n.String(), 10, 64)
	if err != nil {
		return Invalid(path, "expected 64-bit unsigned integer, got %s", n)
	}
	if max != nil && u > *max {
		return Invalid(path, "%d is above maximum %d", u, *max)
	}
	return nil
}

// CheckNull checks that v is JSON null.
func CheckNull(v any, path string) error {
	if v != nil {
		return Invalid(path, "expected null, got %s", jsonKind(v))
	}
	return nil
}

// RequireFields checks that every name is present.
func RequireFields(o map[string]any, path string, names ...string) error {
	for _, n := range names {
		if _, ok := o[n]; !ok {
			return Invalid(path, "missing required property %q", n)
		}
	}
	return nil
}

// OnlyFields rejects properties outside allowed (additionalProperties false).
func OnlyFields(o map[string]any, path string, allowed ...string) error {
	for k := range o {
		found := false
		for _, a := range allowed {
			if k == a {
				found = true
				break
			}
		}
		if !found {
			return Invalid(path, "unexpected property %q", k)
		}
	}
	return nil
}

// I64 and U64 return pointers for generated bound checks.
func I64(v int64) *int64   { return &v }
func U64(v uint64) *uint64 { return &v }

var pointerEscaper = strings.NewReplacer("~", "~0", "/", "~1")

// Field appends a property name to a JSON Pointer.
func Field(path, name string) string { return path + "/" + pointerEscaper.Replace(name) }

// Index appends an array index to a JSON Pointer.
func Index(path string, i int) string { return path + "/" + strconv.Itoa(i) }

func jsonKind(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case bool:
		return "boolean"
	case json.Number, float64:
		return "number"
	case string:
		return "string"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	default:
		return fmt.Sprintf("%T", v)
	}
}

// Int and F64 return pointers for generated bound checks.
func Int(v int) *int         { return &v }
func F64(v float64) *float64 { return &v }

// CheckStringLength checks a string's length in Unicode code points, as JSON
// Schema counts it.
func CheckStringLength(v any, path string, min, max *int) error {
	n := utf8.RuneCountInString(v.(string))
	if min != nil && n < *min {
		return Invalid(path, "string is shorter than %d", *min)
	}
	if max != nil && n > *max {
		return Invalid(path, "string is longer than %d", *max)
	}
	return nil
}

// CheckPattern checks a string against a schema pattern (unanchored, as JSON
// Schema requires).
func CheckPattern(v any, path string, re *regexp.Regexp) error {
	if !re.MatchString(v.(string)) {
		return Invalid(path, "string does not match %q", re.String())
	}
	return nil
}

// CheckItems checks an array's length.
func CheckItems(n int, path string, min, max *int) error {
	if min != nil && n < *min {
		return Invalid(path, "array has fewer than %d items", *min)
	}
	if max != nil && n > *max {
		return Invalid(path, "array has more than %d items", *max)
	}
	return nil
}

// CheckNumberRange checks that v is a number within the given bounds.
func CheckNumberRange(v any, path string, min, max, exMin, exMax *float64) error {
	if err := CheckNumber(v, path); err != nil {
		return err
	}
	f, _ := v.(json.Number).Float64()
	switch {
	case min != nil && f < *min:
		return Invalid(path, "%v is below minimum %v", f, *min)
	case max != nil && f > *max:
		return Invalid(path, "%v is above maximum %v", f, *max)
	case exMin != nil && f <= *exMin:
		return Invalid(path, "%v is not above %v", f, *exMin)
	case exMax != nil && f >= *exMax:
		return Invalid(path, "%v is not below %v", f, *exMax)
	}
	return nil
}
