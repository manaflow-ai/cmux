package com.cmux;

public record SurfaceEvent(String event, long surface, Long runtimeMs) implements CmuxEvent {}
