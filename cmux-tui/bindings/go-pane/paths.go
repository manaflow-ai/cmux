package pane

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
)

// ErrPathOutsideRoots is wrapped by ConfinePath refusals.
var ErrPathOutsideRoots = errors.New("pane: path is not inside the token's roots")

// ConfinePath canonicalizes path (absolute, "..", symlinks; it must exist) and
// returns the canonical form when it lies inside one of roots, compared by
// path components, so /a/rootx is not inside /a/root. Each root is
// canonicalized too. No roots allows no path (decision 20).
func ConfinePath(path string, roots []string) (string, error) {
	if len(roots) == 0 {
		return "", fmt.Errorf("%w: the token has no roots", ErrPathOutsideRoots)
	}
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("%w: %q is not absolute", ErrPathOutsideRoots, path)
	}
	canonical, err := filepath.EvalSymlinks(filepath.Clean(path))
	if err != nil {
		return "", fmt.Errorf("%w: %q cannot be resolved", ErrPathOutsideRoots, path)
	}
	for _, root := range roots {
		if !filepath.IsAbs(root) {
			continue
		}
		r, err := filepath.EvalSymlinks(filepath.Clean(root))
		if err != nil {
			continue
		}
		if canonical == r || r == string(filepath.Separator) ||
			strings.HasPrefix(canonical, r+string(filepath.Separator)) {
			return canonical, nil
		}
	}
	return "", fmt.Errorf("%w: %q", ErrPathOutsideRoots, path)
}

// confineParams confines each named path param and rewrites it to its
// canonical form. A path param that is absent, null or not a string is left
// for the op's validator; any path-taking op needs roots (fail closed, also
// on the router connection, which carries no token).
func confineParams(params json.RawMessage, names []string, roots []string) (json.RawMessage, error) {
	if len(roots) == 0 {
		return nil, Errorf(CodeForbidden, "this op takes a path and the token grants no roots")
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(params, &obj); err != nil {
		return params, nil // not an object: the validator refuses it
	}
	changed := false
	for _, name := range names {
		raw, ok := obj[name]
		if !ok {
			continue
		}
		var p string
		if json.Unmarshal(raw, &p) != nil {
			continue
		}
		canonical, err := ConfinePath(p, roots)
		if err != nil {
			e := Errorf(CodeForbidden, "%s: %v", name, err)
			e.Details, _ = json.Marshal(map[string]string{"param": name})
			return nil, e
		}
		if canonical != p {
			obj[name], _ = json.Marshal(canonical)
			changed = true
		}
	}
	if !changed {
		return params, nil
	}
	return json.Marshal(obj)
}
