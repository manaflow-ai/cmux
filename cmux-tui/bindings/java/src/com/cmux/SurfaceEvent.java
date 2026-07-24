package com.cmux;

public record SurfaceEvent(String event, long surface) implements CmuxEvent {}
