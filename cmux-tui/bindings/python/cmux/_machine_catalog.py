"""Sparse machine response-format options; no route or execution authority."""
from typing import Any, Dict


def catalog_params(catalog: bool) -> Dict[str, Any]:
    if not isinstance(catalog, bool):
        raise TypeError("catalog must be a bool")
    return {"catalog": True} if catalog else {}
